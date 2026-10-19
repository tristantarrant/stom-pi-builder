#!/bin/bash

setup() {
  MACHINE_ARCH=$(gcc -dumpmachine|cut -d- -f1)
  case $MACHINE_ARCH in
    x86_64)
      CPU_ARCH=x86_64
      ;;
    aarch64)
      CPU_ARCH=$(gcc -mcpu=native -### -x c /dev/null 2>&1 | grep -oP 'march=\K[^ "]+' | cut -d+ -f1)
      ;;
    arm)
      CPU_ARCH=$(gcc -march=native -Q --help=target -v 2> /dev/null|grep -- "^  -march"|tr -d ' \t'|cut -d= -f2|cut -d+ -f1)
      ;;
  esac
  export MACHINE_ARCH
  export CPU_ARCH

  # Set CPU-optimized compiler flags
  case $MACHINE_ARCH in
    aarch64)
      export CFLAGS="-mcpu=native -O3 -ffast-math -fdata-sections -ffunction-sections"
      export CXXFLAGS="$CFLAGS"
      # NOOPT=true skips x86 SSE flags in DPF/tap Makefiles; on aarch64 we
      # provide proper flags instead
      export NOOPT=true
      ;;
  esac

  mkdir -p "$WORK_DIR"/build
  mkdir -p "$WORK_DIR"/download
  mkdir -p "$TARGET_DIR"
  mkdir -p "$PREFIX_DIR"
  mkdir -p "$LV2_DIR"
}

parse() {
  NAME=$(yq eval '.plugin.name' "$1")
  VERSION=$(yq eval '.plugin.version' "$1")
  PLUGIN_TYPE=$(yq eval '.plugin.type // "lv2"' "$1")
  SOURCE_TYPE=$(yq eval '.plugin.source.type' "$1")
  BUILD_COMMANDS=$(yq ".plugin.build" "$1"| sed "s/^- //")
  INSTALL_COMMANDS=$(yq ".plugin.install" "$1"| sed "s/^- //")
  DATA_TYPE=$(yq eval '.plugin.data.type' "$1")
  BUNDLES=$(yq eval '.plugin.bundles[]' "$1" 2>/dev/null)
  DEPENDENCIES=$(yq eval '.plugin.dependencies[]' "$1" 2>/dev/null)
  MODGUI_BRAND=$(yq eval '.plugin.modgui.brand' "$1" 2>/dev/null)
  MODGUI_COLOR=$(yq eval '.plugin.modgui.color' "$1" 2>/dev/null)
  MODGUI_KNOB=$(yq eval '.plugin.modgui.knob' "$1" 2>/dev/null)
  PLUGIN_DESCRIPTION=$(yq eval '.plugin.modgui.description // ""' "$1" 2>/dev/null)
  PLUGIN_DIR=$(pwd)/$(dirname "$1")
  SOURCE_DIR="$WORK_DIR/build/$NAME-$VERSION"
}

check_dependencies() {
  if [ -z "$DEPENDENCIES" ]; then
    return 0
  fi
  MISSING=""
  for pkg in $DEPENDENCIES; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      MISSING="$MISSING $pkg"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "=== Missing dependencies for $NAME:$MISSING ==="
    read -r -p "Install them now? [Y/n] " answer
    case "$answer" in
      [nN]*)
        echo "Skipping $NAME (missing dependencies)"
        return 1
        ;;
      *)
        sudo apt-get install -y $MISSING || return 1
        ;;
    esac
  fi
  return 0
}

# Rewrite SSH-style submodule URLs in .gitmodules to HTTPS so submodules can be fetched without authentication. Handles scp-like `user@host:path` and scheme-form `ssh://[user]@host[:port]/path`; http(s)/git/file URLs are left alone. Must run after cloning, before resolving submodules; a no-op when the file is missing or nothing converts (only logs when it changes something).
rewrite_ssh_submodule_urls() {
  local gitmodules="$1/.gitmodules"
  [ -f "$gitmodules" ] || return 0
  grep -Eq 'url[[:space:]]*=[[:space:]]*"?(ssh://|[A-Za-z0-9._%-]+@)' "$gitmodules" || return 0

  python3 - "$gitmodules" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    original = f.read()

changed = []


def record(url, m):
    changed.append(url)
    return '{0}{1}'.format(m['prefix'], url)


# scp-style: [ws]url[ws]=[ws]"?user@host:path"?  -> https://host/path
scp = re.compile(
    r'^(?P<prefix>\s*url\s*=\s*)'   # leading whitespace + "url ="
    r'"?'                           # optional opening quote
    r'[A-Za-z0-9._%-]+@'            # user (any username, e.g. git) -> dropped
    r'(?P<host>[A-Za-z0-9.-]+)'     # host
    r':'                            # scp-style colon separator
    r'(?P<p>\S+?)'                  # repository path (no whitespace/quote)
    r'"?\s*$',                      # optional closing quote + end of line
    flags=re.M,
)


def rewrite_scp(m):
    return record('https://{0}/{1}'.format(m['host'], m['p']), m)


# scheme form: [ws]url[ws]=[ws]"?ssh://user@host[:port]/path"?  -> https://host[:port]/path
sshs = re.compile(
    r'^(?P<prefix>\s*url\s*=\s*)'   # leading whitespace + "url ="
    r'"?'                           # optional opening quote
    r'ssh://'                       # explicit scheme, literal
    r'(?:[A-Za-z0-9._%-]+@)?'       # optional user -> dropped
    r'(?P<host>[A-Za-z0-9.-]+)'     # host
    r'(?::(?P<port>\d+))?'          # optional explicit port (kept)
    r'/'                            # path separator, literal slash
    r'(?P<p>\S+?)'                  # repository path (no whitespace/quote)
    r'"?\s*$',                      # optional closing quote + end of line
    flags=re.M,
)


def rewrite_sshs(m):
    if m['port']:
        url = 'https://{0}:{1}/{2}'.format(m['host'], m['port'], m['p'])
    else:
        url = 'https://{0}/{1}'.format(m['host'], m['p'])
    return record(url, m)


converted = scp.sub(rewrite_scp, original)
converted = sshs.sub(rewrite_sshs, converted)

if converted != original:
    with open(path, 'w') as f:
        f.write(converted)
    print('Converting SSH submodule URLs to HTTPS in .gitmodules:')
    for url in changed:
        print('  -> {0}'.format(url))
PYEOF
}

# Resolve submodules recursively, fetching as little history as possible. Each level's direct children are marked for depth-1 clones before init (git deepens automatically when the pinned commit is not on its default branch tip). It also recurses into every resolved subproject that carries its own .gitmodules, rewriting SSH-style URLs there before resolving them.
resolve_submodules() {
  local dir="$1" key name path

  [ -f "$dir/.gitmodules" ] || return 0

  # SSH-style submodule URLs require authentication; rewrite before resolving
  rewrite_ssh_submodule_urls "$dir"

  while IFS= read -r key; do
    name=${key#submodule.}
    name=${name%.path}
    git -C "$dir" config "submodule.$name.shallow" true \
      || echo "Warning: could not mark submodule '$name' for shallow clone (fetching full history)"
  done < <(git config -f "$dir/.gitmodules" --name-only --get-regexp '^submodule\..*\.path$')

  git -C "$dir" submodule update --init || return 1

  while IFS= read -r key; do
    name=${key#submodule.}
    name=${name%.path}
    path=$(git config -f "$dir/.gitmodules" "submodule.$name.path")
    if [ -d "$dir/$path" ]; then
      resolve_submodules "$dir/$path" || return 1
    fi
  done < <(git config -f "$dir/.gitmodules" --name-only --get-regexp '^submodule\..*\.path$')
}

download() {
  echo "=== Download: $NAME ==="
  case $SOURCE_TYPE in
    http)
      URL=$(yq eval '.plugin.source.url' "$1")
      DOWNLOAD="$WORK_DIR/download/$NAME-$VERSION.tar.gz"
      if [ ! -f "$DOWNLOAD" ]; then
        wget -O "$DOWNLOAD" "$URL"
      fi
      pushd "$WORK_DIR/build" > /dev/null || return 1
      tar xzf "$DOWNLOAD" || { popd > /dev/null; return 1; }
      cd "$NAME"* || { popd > /dev/null; return 1; }
      popd > /dev/null || return 1
      ;;
    git)
      if [ ! -d "$SOURCE_DIR" ]; then
        URL=$(yq eval '.plugin.source.url' "$1")
        pushd "$WORK_DIR/build" > /dev/null || return 1
        # Clone without recursing submodules: SSH-style URLs in .gitmodules must be rewritten first (they would require authentication)
        if [[ "$VERSION" =~ ^[0-9a-f]{40}$ ]]; then
          git clone "$URL" "$NAME-$VERSION" || { popd > /dev/null; return 1; }
          git -C "$NAME-$VERSION" checkout "$VERSION" || { popd > /dev/null; return 1; }
        else
          git clone --branch "$VERSION" --depth 1 "$URL" "$NAME-$VERSION" || { popd > /dev/null; return 1; }
          # Resolve submodules shallowly, rewriting SSH-style URLs in .gitmodules first (they would require authentication)
          resolve_submodules "$SOURCE_DIR" || { rm -rf "$SOURCE_DIR"; popd > /dev/null; return 1; }
        fi
        popd > /dev/null
      fi
      ;;
    *)
      echo "Unknown source type in $1"
      return
      ;;
  esac
}

prepare() {
  echo "=== Patch: $NAME ==="
  # Apply shared nih-plug GUI removal for VST3 plugins
  if [ "$PLUGIN_TYPE" = "vst3" ] && [ -f "$RESOLVED_DIR/data/patches/nih-plug-disable-gui.patch" ]; then
    echo "Applying nih-plug GUI disable patch"
    patch -d "$SOURCE_DIR" -N -p1 -i "$RESOLVED_DIR/data/patches/nih-plug-disable-gui.patch" || true
    # Remove mod gui and editor function from lib.rs
    if [ -f "$SOURCE_DIR/src/lib.rs" ]; then
      sed -i '/^mod gui;/d' "$SOURCE_DIR/src/lib.rs"
      sed -i '/fn editor(.*AsyncExecutor/,/^    }/d' "$SOURCE_DIR/src/lib.rs"
    fi
  fi
  # Apply per-plugin patches
  find "$PLUGIN_DIR" -name "*.patch" -type f -print -exec patch -d "$SOURCE_DIR" -N -p1 -i {} \;
  if [ -d "$PLUGIN_DIR/overlay" ]; then
     cp -rv "$PLUGIN_DIR"/overlay/* "$SOURCE_DIR"
  fi
}

build() {
  pushd "$SOURCE_DIR" > /dev/null || return 1
  while IFS= read -r line; do
      echo "Executing: $line"
      if ! eval "$line"; then
        echo "FAILED: $NAME (build command: $line)"
        popd > /dev/null
        return 1
      fi
  done <<< "$BUILD_COMMANDS"
  popd > /dev/null
}

install() {
  echo "=== Install: $NAME ==="
  if [ -n "$BUNDLES" ]; then
    PLUGINS="$BUNDLES"
  else
    PLUGINS=$(find "$SOURCE_DIR" -type d -name "*.lv2" -exec basename {} \;| sort|uniq)
  fi
  echo "Bundles:"
  echo "$PLUGINS"
  pushd "$SOURCE_DIR" > /dev/null || return 1
  while IFS= read -r line; do
      echo "Executing: ${line}"
      if ! eval "$line"; then
        echo "FAILED: $NAME (install command: $line)"
        popd > /dev/null
        return 1
      fi
  done <<< "$INSTALL_COMMANDS"
  popd > /dev/null

  case $DATA_TYPE in
    local)
      ;;
    null)
      # Merge prebuilt metadata bundles (modgui assets, presets, ...) from the shared data/ dirs.
      # --no-clobber: files produced by our own build above are authoritative. A stale copy under
      # data/ can desync port definitions vs the freshly compiled .so and crash hosts at runtime
      # (e.g. mod-lv2-data's midifilter.lv2 predates x42 master's "hold"/c2/c4 ports, which made
      # filter_preproc_midichord dereference NULL config buffers in jackd). Data copies only fill
      # gaps our build did not produce.
      for PLUGIN in $PLUGINS; do
        find "$DIR/data" -name "$PLUGIN" -type d -exec cp -rnv {} "$LV2_DIR" \;
      done
      ;;
    *)
      # Same no-clobber rule: never replace files our build just installed.
      find "$DIR/data" -name "$DATA_TYPE" -type d -exec cp -rvn {} "$LV2_DIR" \;
      ;;
  esac
}

package() {
  echo "=== Package: $NAME ==="
  BUILD_DATE=$(git -C "$SOURCE_DIR" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
  PACKAGE_DIR="$WORK_DIR/packages"
  mkdir -p "$PACKAGE_DIR"

  if [ "$PLUGIN_TYPE" = "vst3" ]; then
    # VST3 plugins: bundle both .vst3 and .lv2 wrapper into a single archive
    local staging="$WORK_DIR/staging/$NAME"
    rm -rf "$staging"
    mkdir -p "$staging/lv2" "$staging/vst3"

    for BUNDLE in $PLUGINS; do
      local BUNDLE_PATH="$LV2_DIR/$BUNDLE"
      [ -d "$BUNDLE_PATH" ] && cp -r "$BUNDLE_PATH" "$staging/lv2/"
    done

    # Include .vst3 bundles matching this plugin
    find "$PREFIX_DIR" -maxdepth 3 -type d -name "${NAME}.vst3" -exec cp -r {} "$staging/vst3/" \;

    ARCHIVE_NAME="${NAME}-${VERSION}-${BUILD_DATE}-${MACHINE_ARCH}.tar.gz"
    tar -czf "$PACKAGE_DIR/$ARCHIVE_NAME" -C "$WORK_DIR/staging" "$NAME"
    echo "Packaged: $PACKAGE_DIR/$ARCHIVE_NAME"
    rm -rf "$staging"
  else
    for BUNDLE in $PLUGINS; do
      BUNDLE_PATH="$LV2_DIR/$BUNDLE"
      if [ ! -d "$BUNDLE_PATH" ]; then
        echo "Warning: bundle $BUNDLE not found at $BUNDLE_PATH, skipping"
        continue
      fi
      ARCHIVE_NAME="${BUNDLE%.lv2}-${VERSION}-${BUILD_DATE}-${MACHINE_ARCH}.tar.gz"
      tar -czf "$PACKAGE_DIR/$ARCHIVE_NAME" -C "$LV2_DIR" "$BUNDLE"
      echo "Packaged: $PACKAGE_DIR/$ARCHIVE_NAME"
    done
  fi
}

BOX_COLORS=(black blue brown cream cyan darkblue dots flowerpower gold gray green lava orange petrol pink purple racing red slime tribal1 tribal2 warning white wood0 wood1 wood2 wood3 wood4 yellow zinc)
KNOB_COLORS=(aluminium black blue bronze copper gold green petrol purple silver steel)

pick_style() {
  local name="$1" seed="$2"
  shift 2
  local arr=("$@")
  local hash=$(echo -n "${name}${seed}" | cksum | cut -d' ' -f1)
  echo "${arr[$((hash % ${#arr[@]}))]}"
}

generate_modgui() {
  [ "$MODGUI_BRAND" = "null" ] && return
  local RESOURCE_DIR="$RESOLVED_DIR/data/modgui-resources"
  [ -d "$RESOURCE_DIR" ] || { echo "Warning: modgui resources not found at $RESOURCE_DIR"; return; }

  for bundle in $PLUGINS; do
    local bundle_dir="$LV2_DIR/$bundle"
    [ -d "$bundle_dir" ] || continue
    [ -d "$bundle_dir/modgui" ] && continue

    local bundle_name=$(basename "$bundle_dir")
    local plugin_short="${bundle_name%.lv2}"
    local lower_name=$(echo "$plugin_short" | tr '[:upper:]' '[:lower:]')

    # Find plugin TTL (not manifest/modgui)
    local ttl_file=$(find "$bundle_dir" -name "*.ttl" ! -name "manifest.ttl" ! -name "modgui.ttl" | head -1)
    [ -z "$ttl_file" ] && continue

    # Get plugin URI and display name
    local uri=$(grep -B1 'a lv2:Plugin' "$bundle_dir/manifest.ttl" | grep -oP '<[^>]+>' | grep -v 'lv2plug.in' | head -1 | tr -d '<>')
    [ -z "$uri" ] && continue
    local display_name=$(grep 'doap:name' "$ttl_file" | head -1 | grep -oP '"[^"]+"' | tr -d '"')
    [ -z "$display_name" ] && display_name="$plugin_short"

    # Parse control ports
    local ports_data=$(python3 -c "
import re
with open('$ttl_file') as f:
    content = f.read()
ports = re.split(r'\]\s*[;,.]', content)
results = []
for port in ports:
    if 'ControlPort' in port and 'InputPort' in port:
        idx_m = re.search(r'lv2:index\s+(\d+)', port)
        sym_m = re.search(r'lv2:symbol\s+\"([^\"]+)\"', port)
        name_m = re.search(r'lv2:name\s+\"([^\"]+)\"', port)
        if idx_m and sym_m and name_m:
            results.append((int(idx_m.group(1)), sym_m.group(1), name_m.group(1)))
results.sort()
for idx, sym, name in results:
    print(f'{idx}|{sym}|{name}')
" 2>/dev/null)
    local num_ports=0
    [ -n "$ports_data" ] && num_ports=$(echo "$ports_data" | grep -c '|')

    # Determine styles
    local box_color="$MODGUI_COLOR"
    [ "$box_color" = "null" ] && box_color=$(pick_style "$plugin_short" "" "${BOX_COLORS[@]}")
    local knob_color="$MODGUI_KNOB"
    [ "$knob_color" = "null" ] && knob_color=$(pick_style "$plugin_short" "knob" "${KNOB_COLORS[@]}")
    local brand="$MODGUI_BRAND"

    # Panel info from port count
    local panel model css_class
    case $num_ports in
      0) panel="1-footswitch"; model="boxy-small"; css_class="mod-one-footswitch";;
      1) panel="1-knob"; model="boxy"; css_class="mod-one-knob";;
      2) panel="2-knobs"; model="boxy"; css_class="mod-two-knobs";;
      3) panel="3-knobs"; model="boxy"; css_class="mod-three-knobs";;
      4) panel="4-knobs"; model="boxy"; css_class="mod-four-knobs";;
      5) panel="5-knobs"; model="boxy"; css_class="mod-five-knobs";;
      6) panel="6-knobs"; model="boxy"; css_class="mod-six-knobs";;
      7) panel="7-knobs"; model="boxy"; css_class="mod-seven-knobs";;
      *) panel="8-knobs"; model="boxy"; css_class="mod-eight-knobs";;
    esac

    echo "MODGUI: $bundle_name ($num_ports knobs, $model, $box_color, knob=$knob_color)"

    # Create modgui directory and copy resources
    mkdir -p "$bundle_dir/modgui/pedals/$model"
    [ -f "$RESOURCE_DIR/pedals/$model/$box_color.png" ] && cp "$RESOURCE_DIR/pedals/$model/$box_color.png" "$bundle_dir/modgui/pedals/$model/"
    [ -f "$RESOURCE_DIR/pedals/footswitch.png" ] && cp "$RESOURCE_DIR/pedals/footswitch.png" "$bundle_dir/modgui/pedals/"
    # Generate screenshot from pedal background + brand/label + knobs
    local pedal_bg="$RESOURCE_DIR/pedals/$model/$box_color.png"
    [ ! -f "$pedal_bg" ] && pedal_bg="$RESOURCE_DIR/pedals/boxy/$box_color.png"
    local scrn="$bundle_dir/modgui/screenshot-$lower_name.png"
    local thumb="$bundle_dir/modgui/thumbnail-$lower_name.png"
    if [ -f "$pedal_bg" ] && command -v convert >/dev/null 2>&1; then
      local brand_y=170 label_y=280 knob_y=40
      [ "$model" = "boxy-small" ] && brand_y=20 && label_y=85 && knob_y=0
      # Start with pedal background + text
      convert "$pedal_bg" \
        -font Helvetica-Bold -pointsize 16 -fill black \
        -gravity North -annotate +0+"$brand_y" "$brand" \
        -pointsize 14 -annotate +0+"$label_y" "$display_name" \
        "$scrn"
      # Composite knobs if the plugin has control ports
      if [ "$num_ports" -gt 0 ]; then
        local knob_sprite="$RESOURCE_DIR/knobs/boxy/$knob_color.png"
        if [ -f "$knob_sprite" ]; then
          local sprite_h=$(identify -format '%h' "$knob_sprite")
          local frame_sz=$sprite_h
          local knob_frame=$(mktemp /tmp/knob-XXXXXX.png)
          # Extract middle frame (~50% rotation) from sprite strip
          convert "$knob_sprite" -crop "${frame_sz}x${frame_sz}+$((32 * frame_sz))+0" +repage "$knob_frame"
          local bg_w=$(identify -format '%w' "$pedal_bg")
          local max_knob=55
          [ "$num_ports" -le 2 ] && max_knob=70
          local avail=$((bg_w - 20))
          local per_knob=$((avail / num_ports))
          [ "$per_knob" -gt "$max_knob" ] && per_knob=$max_knob
          local total_w=$((per_knob * num_ports))
          local start_x=$(( (bg_w - total_w) / 2 ))
          # Scale the knob frame once
          local scaled_knob=$(mktemp /tmp/knob-scaled-XXXXXX.png)
          convert "$knob_frame" -resize "${per_knob}x${per_knob}" "$scaled_knob"
          # Composite each knob position sequentially
          for i in $(seq 0 $((num_ports - 1))); do
            local kx=$((start_x + i * per_knob))
            convert "$scrn" "$scaled_knob" -gravity NorthWest -geometry "+${kx}+${knob_y}" -composite "$scrn"
          done
          rm -f "$knob_frame" "$scaled_knob"
        fi
      fi
      convert "$scrn" -resize 64x64 "$thumb"
    else
      cp "$RESOURCE_DIR/pedals/default-screenshot.png" "$scrn"
      cp "$RESOURCE_DIR/pedals/default-thumbnail.png" "$thumb"
    fi

    # Copy knob images
    if [ "$num_ports" -gt 0 ]; then
      mkdir -p "$bundle_dir/modgui/knobs/boxy"
      cp "$RESOURCE_DIR/knobs/boxy/$knob_color.png" "$bundle_dir/modgui/knobs/boxy/" 2>/dev/null
      cp "$RESOURCE_DIR/knobs/boxy/boxy.png" "$bundle_dir/modgui/knobs/boxy/" 2>/dev/null
    fi

    # CSS — /resources/ paths are served from plugin's resourcesDirectory via ?uri= param
    cat "$RESOURCE_DIR/pedals/$model/$model.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css" 2>/dev/null || \
    cat "$RESOURCE_DIR/pedals/boxy/boxy.css" > "$bundle_dir/modgui/stylesheet-$lower_name.css"
    [ "$num_ports" -gt 0 ] && cat "$RESOURCE_DIR/knobs/boxy/boxy.css" >> "$bundle_dir/modgui/stylesheet-$lower_name.css"

    # HTML template
    if [ "$num_ports" -eq 0 ]; then
      cat > "$bundle_dir/modgui/icon-$lower_name.html" << 'HTMLEOF'
<div class="mod-pedal mod-pedal-boxy{{{cns}}} mod-boxy50 mod-one-footswitch mod-{{color}} {{color}}">
    <div mod-role="drag-handle" class="mod-drag-handle"></div>
    <div class="mod-plugin-brand"><h1>{{brand}}</h1></div>
    <div class="mod-plugin-name"><h1>{{label}}</h1></div>
    <div class="mod-light on" mod-role="bypass-light"></div>
    <div class="mod-footswitch" mod-role="bypass"></div>
    <div class="mod-pedal-input">
        {{#effect.ports.audio.input}}
        <div class="mod-input mod-input-disconnected" title="{{name}}" mod-role="input-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-input-image"></div>
        </div>
        {{/effect.ports.audio.input}}
    </div>
    <div class="mod-pedal-output">
        {{#effect.ports.audio.output}}
        <div class="mod-output mod-output-disconnected" title="{{name}}" mod-role="output-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-output-image"></div>
        </div>
        {{/effect.ports.audio.output}}
    </div>
</div>
HTMLEOF
    else
      cat > "$bundle_dir/modgui/icon-$lower_name.html" << HTMLEOF
<div class="mod-pedal mod-pedal-boxy{{{cns}}} $css_class mod-{{color}} {{color}}">
    <div mod-role="drag-handle" class="mod-drag-handle"></div>
    <div class="mod-plugin-brand"><h1>{{brand}}</h1></div>
    <div class="mod-plugin-name"><h1>{{label}}</h1></div>
    <div class="mod-light on" mod-role="bypass-light"></div>
    <div class="mod-control-group mod-{{knob}} clearfix">
        {{#controls}}
        <div class="mod-knob" title="{{comment}}">
            <div class="mod-knob-image" mod-role="input-control-port" mod-port-symbol="{{symbol}}"></div>
            <span class="mod-knob-title">{{name}}</span>
        </div>
        {{/controls}}
    </div>
    <div class="mod-footswitch" mod-role="bypass"></div>
    <div class="mod-pedal-input">
        {{#effect.ports.audio.input}}
        <div class="mod-input mod-input-disconnected" title="{{name}}" mod-role="input-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-input-image"></div>
        </div>
        {{/effect.ports.audio.input}}
    </div>
    <div class="mod-pedal-output">
        {{#effect.ports.audio.output}}
        <div class="mod-output mod-output-disconnected" title="{{name}}" mod-role="output-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-output-image"></div>
        </div>
        {{/effect.ports.audio.output}}
    </div>
</div>
HTMLEOF
    fi

    # Generate modgui.ttl
    {
      echo '@prefix modgui: <http://moddevices.com/ns/modgui#> .'
      echo '@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .'
      echo ''
      echo "<$uri>"
      echo '    modgui:gui ['
      echo "        modgui:resourcesDirectory <modgui> ;"
      echo "        modgui:iconTemplate <modgui/icon-$lower_name.html> ;"
      echo "        modgui:stylesheet <modgui/stylesheet-$lower_name.css> ;"
      echo "        modgui:screenshot <modgui/screenshot-$lower_name.png> ;"
      echo "        modgui:thumbnail <modgui/thumbnail-$lower_name.png> ;"
      echo "        modgui:brand \"$brand\" ;"
      echo "        modgui:label \"$display_name\" ;"
      echo "        modgui:model \"$model\" ;"
      echo "        modgui:panel \"$panel\" ;"
      echo "        modgui:color \"$box_color\" ;"
      if [ "$num_ports" -gt 0 ]; then
        echo "        modgui:knob \"$knob_color\" ;"
        local first=true
        while IFS='|' read -r idx sym pname; do
          [ -z "$idx" ] && continue
          if [ "$first" = true ]; then
            echo '        modgui:port ['
            first=false
          else
            echo '        ] , ['
          fi
          echo "            lv2:index $idx ;"
          echo "            lv2:symbol \"$sym\" ;"
          echo "            lv2:name \"$pname\" ;"
        done <<< "$ports_data"
        echo '        ] ;'
      fi
      echo '    ] .'
    } > "$bundle_dir/modgui.ttl"

    # Add modgui.ttl reference to manifest.ttl
    if ! grep -q "modgui.ttl" "$bundle_dir/manifest.ttl"; then
      # Ensure rdfs prefix exists
      grep -q 'rdfs:' "$bundle_dir/manifest.ttl" || sed -i '1i @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .' "$bundle_dir/manifest.ttl"
      echo "<$uri> rdfs:seeAlso <modgui.ttl> ." >> "$bundle_dir/manifest.ttl"
    fi
  done
}

inject_description() {
  [ -z "$PLUGIN_DESCRIPTION" ] || [ "$PLUGIN_DESCRIPTION" = "null" ] && return

  for bundle in $PLUGINS; do
    local bundle_dir="$LV2_DIR/$bundle"
    [ -d "$bundle_dir" ] || continue

    # Find plugin URI from manifest
    local uri=$(grep -oP '<[^>]+>' "$bundle_dir/manifest.ttl" 2>/dev/null | grep -v 'lv2plug.in\|w3.org\|moddevices' | head -1 | tr -d '<>')
    [ -z "$uri" ] && continue

    # Find a TTL file to add the comment to (prefer modgui.ttl, fall back to main TTL)
    local target_ttl=""
    if [ -f "$bundle_dir/modgui.ttl" ]; then
      target_ttl="$bundle_dir/modgui.ttl"
    else
      target_ttl=$(find "$bundle_dir" -name "*.ttl" ! -name "manifest.ttl" | head -1)
    fi
    [ -z "$target_ttl" ] && continue

    # Skip if already has rdfs:comment
    grep -q 'rdfs:comment' "$target_ttl" && continue

    # Ensure rdfs prefix exists
    grep -q '@prefix rdfs:' "$target_ttl" || sed -i '1i @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .' "$target_ttl"

    echo "" >> "$target_ttl"
    echo "<$uri> rdfs:comment \"$PLUGIN_DESCRIPTION\" ." >> "$target_ttl"
    echo "DESCRIPTION: $bundle ($PLUGIN_DESCRIPTION)"
  done
}

generate_vst3_wrapper() {
  echo "=== VST3 Wrapper: $NAME ==="

  local VST3_SCAN="${VST3_SCAN:-rustyfoot-vst3-scan}"
  if ! command -v "$VST3_SCAN" >/dev/null 2>&1; then
    echo "Warning: $VST3_SCAN not found, skipping VST3 wrapper generation"
    return 1
  fi

  local VST3_WRAPPER_SO="${VST3_WRAPPER_SO:-/usr/lib/rustyfoot/vst3-wrapper.so}"

  # Find .vst3 bundles matching this plugin name
  local vst3_bundles=$(find "$PREFIX_DIR" -maxdepth 3 -type d -name "${NAME}.vst3" 2>/dev/null)
  if [ -z "$vst3_bundles" ]; then
    echo "Warning: no .vst3 bundles found in $PREFIX_DIR"
    return 1
  fi

  for vst3_bundle in $vst3_bundles; do
    local vst3_name=$(basename "$vst3_bundle" .vst3)
    local lv2_bundle_dir="$LV2_DIR/${vst3_name}.lv2"

    echo "Scanning: $vst3_bundle"
    rm -rf "$lv2_bundle_dir"
    mkdir -p "$lv2_bundle_dir"

    # Run scanner to generate wrapper.json
    if ! "$VST3_SCAN" "$vst3_bundle" "$lv2_bundle_dir" 2>&1; then
      echo "FAILED: VST3 scan for $vst3_bundle"
      rm -rf "$lv2_bundle_dir"
      return 1
    fi

    # Read wrapper.json to get plugin metadata for TTL generation
    local wrapper_json="$lv2_bundle_dir/wrapper.json"
    [ ! -f "$wrapper_json" ] && { echo "FAILED: no wrapper.json generated"; return 1; }

    local plugin_uri=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d['uri'])")
    local plugin_name=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d['name'])")
    local plugin_maker=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d.get('maker',''))")
    local plugin_license=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d.get('license',''))")
    local plugin_category=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d.get('category','lv2:Plugin'))")
    local audio_ins=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d['audio_inputs'])")
    local audio_outs=$(python3 -c "import json; d=json.load(open('$wrapper_json')); print(d['audio_outputs'])")

    echo "Generating TTL: $plugin_uri ($plugin_name)"

    # Generate manifest.ttl
    cat > "$lv2_bundle_dir/manifest.ttl" << TTLEOF
@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<$plugin_uri>
    a lv2:Plugin ;
    lv2:binary <vst3-wrapper.so> ;
    rdfs:seeAlso <${vst3_name}.ttl> , <modgui.ttl> .
TTLEOF

    # Generate plugin TTL with ports from wrapper.json
    PLUGIN_DESCRIPTION="$PLUGIN_DESCRIPTION" python3 -c "
import json

with open('$wrapper_json') as f:
    d = json.load(f)

uri = d['uri']
name = d['name']
maker = d.get('maker', '')
license = d.get('license', '')
category = d.get('category', 'lv2:Plugin')
audio_ins = d['audio_inputs']
audio_outs = d['audio_outputs']
params = d['parameters']

lines = []
lines.append('@prefix atom: <http://lv2plug.in/ns/ext/atom#> .')
lines.append('@prefix doap: <http://usefulinc.com/ns/doap#> .')
lines.append('@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .')
lines.append('@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .')
lines.append('@prefix state: <http://lv2plug.in/ns/ext/state#> .')
lines.append('@prefix urid: <http://lv2plug.in/ns/ext/urid#> .')
lines.append('@prefix units: <http://lv2plug.in/ns/extensions/units#> .')
lines.append('')
lines.append(f'<{uri}>')
lines.append(f'    a lv2:Plugin , {category} ;')
lines.append(f'    doap:name \"{name}\" ;')
if maker:
    lines.append(f'    doap:developer [ doap:name \"{maker}\" ] ;')
if license:
    lines.append(f'    doap:license \"{license}\" ;')
import os
description = os.environ.get('PLUGIN_DESCRIPTION', '')
if description:
    lines.append(f'    rdfs:comment \"{description}\" ;')
lines.append(f'    lv2:requiredFeature urid:map ;')
lines.append(f'    lv2:extensionData state:interface ;')

port_index = 0

# Control input ports
for p in params:
    lines.append(f'    lv2:port [')
    if p.get('toggle'):
        lines.append(f'        a lv2:InputPort , lv2:ControlPort ;')
        lines.append(f'        lv2:index {port_index} ;')
        lines.append(f'        lv2:symbol \"{p[\"lv2_symbol\"]}\" ;')
        lines.append(f'        lv2:name \"{p[\"lv2_name\"]}\" ;')
        lines.append(f'        lv2:portProperty lv2:toggled ;')
        lines.append(f'        lv2:default {p[\"default\"]:.6g} ;')
        lines.append(f'        lv2:minimum {p[\"min\"]:.6g} ;')
        lines.append(f'        lv2:maximum {p[\"max\"]:.6g} ;')
    else:
        lines.append(f'        a lv2:InputPort , lv2:ControlPort ;')
        lines.append(f'        lv2:index {port_index} ;')
        lines.append(f'        lv2:symbol \"{p[\"lv2_symbol\"]}\" ;')
        lines.append(f'        lv2:name \"{p[\"lv2_name\"]}\" ;')
        lines.append(f'        lv2:default {p[\"default\"]:.6g} ;')
        lines.append(f'        lv2:minimum {p[\"min\"]:.6g} ;')
        lines.append(f'        lv2:maximum {p[\"max\"]:.6g} ;')
        if p.get('integer'):
            lines.append(f'        lv2:portProperty lv2:integer ;')
    if p.get('unit'):
        u = p['unit'].strip()
        unit_map = {
            'dB': 'units:db', 'Hz': 'units:hz', 'ms': 'units:ms',
            's': 'units:s', '%': 'units:pc', 'bpm': 'units:bpm',
        }
        if u in unit_map:
            lines.append(f'        units:unit {unit_map[u]} ;')
    lines.append(f'    ] ;')
    port_index += 1

# Audio input ports
for i in range(audio_ins):
    lines.append(f'    lv2:port [')
    lines.append(f'        a lv2:InputPort , lv2:AudioPort ;')
    lines.append(f'        lv2:index {port_index} ;')
    lines.append(f'        lv2:symbol \"in{i + 1}\" ;')
    lines.append(f'        lv2:name \"Audio Input {i + 1}\" ;')
    lines.append(f'    ] ;')
    port_index += 1

# Audio output ports
for i in range(audio_outs):
    sep = '.' if i == audio_outs - 1 else ';'
    lines.append(f'    lv2:port [')
    lines.append(f'        a lv2:OutputPort , lv2:AudioPort ;')
    lines.append(f'        lv2:index {port_index} ;')
    lines.append(f'        lv2:symbol \"out{i + 1}\" ;')
    lines.append(f'        lv2:name \"Audio Output {i + 1}\" ;')
    lines.append(f'    ] {sep}')
    port_index += 1

print('\n'.join(lines))
" > "$lv2_bundle_dir/${vst3_name}.ttl"

    # Create symlink to shared wrapper binary
    ln -sf "$VST3_WRAPPER_SO" "$lv2_bundle_dir/vst3-wrapper.so"

    # Set PLUGINS so generate_modgui and package can find the bundle
    PLUGINS="${vst3_name}.lv2"

    echo "Generated: $lv2_bundle_dir"
  done
}

clean() {
  rm -rf "$SOURCE_DIR"
  rm -f "$WORK_DIR/build/.stamp-$NAME"
}

compute_build_sha() {
  local sha=""
  # Source commit SHA (if git repo exists)
  if [ -d "$SOURCE_DIR/.git" ]; then
    sha=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null)
  fi
  # Hash the descriptor and patches to detect build rule changes
  # Include overlay/ so edits to overlaid sources (e.g. Shared_files/PitchSplicer.*) also invalidate the stamp on existing checkouts.
  local config_hash=$(cat "$PLUGIN_DIR/descriptor.yaml" "$PLUGIN_DIR"/*.patch $(find "$PLUGIN_DIR/overlay" -type f 2>/dev/null) 2>/dev/null | sha1sum | cut -d' ' -f1)
  echo "${sha}-${config_hash}"
}

is_up_to_date() {
  local stamp_file="$WORK_DIR/build/.stamp-$NAME"
  [ ! -f "$stamp_file" ] && return 1
  local current_sha=$(compute_build_sha)
  local stored_sha=$(cat "$stamp_file")
  [ "$current_sha" = "$stored_sha" ]
}

save_build_sha() {
  compute_build_sha > "$WORK_DIR/build/.stamp-$NAME"
}

check_remote_update() {
  local url=$(yq eval '.plugin.source.url' "$1")

  if [ "$SOURCE_TYPE" != "git" ]; then
    printf "  %-30s skipped (not git)\n" "$NAME"
    return
  fi

  local stamp_file="$WORK_DIR/build/.stamp-$NAME"
  if [ ! -f "$stamp_file" ]; then
    printf "  %-30s not built\n" "$NAME"
    NOT_BUILT=$((NOT_BUILT + 1))
    return
  fi

  local stamp=$(cat "$stamp_file")
  local stored_sha=${stamp%%-*}
  local stored_config=${stamp#*-}

  # Keep in sync with compute_build_sha: overlay/ must be part of the config hash too.
  local current_config=$(cat "$PLUGIN_DIR/descriptor.yaml" "$PLUGIN_DIR"/*.patch $(find "$PLUGIN_DIR/overlay" -type f 2>/dev/null) 2>/dev/null | sha1sum | cut -d' ' -f1)
  local config_changed=false
  [ "$current_config" != "$stored_config" ] && config_changed=true

  local ls_output
  ls_output=$(git ls-remote --refs "$url" "refs/heads/$VERSION" "refs/tags/$VERSION" 2>/dev/null)

  if [ -z "$ls_output" ]; then
    printf "  %-30s could not resolve version '%s'\n" "$NAME" "$VERSION"
    return
  fi

  local remote_sha=$(echo "$ls_output" | head -1 | cut -f1)
  local ref_type="branch"
  echo "$ls_output" | grep -q "refs/tags/" && ref_type="tag"

  local short_stored=${stored_sha:0:12}
  local short_remote=${remote_sha:0:12}

  if [ "$remote_sha" = "$stored_sha" ] && [ "$config_changed" = false ]; then
    printf "  %-30s up to date (%s: %s @ %s)\n" "$NAME" "$ref_type" "$VERSION" "$short_stored"
    UP_TO_DATE=$((UP_TO_DATE + 1))
  elif [ "$remote_sha" != "$stored_sha" ]; then
    printf "  %-30s UPDATE (%s: %s %s -> %s)\n" "$NAME" "$ref_type" "$VERSION" "$short_stored" "$short_remote"
    UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
    [ "$config_changed" = true ] && printf "  %-30s   + config also changed\n" ""
  else
    printf "  %-30s config changed (upstream @ %s)\n" "$NAME" "$short_stored"
    CONFIG_CHANGED=$((CONFIG_CHANGED + 1))
  fi
}

### Environment variables
DIR=$(dirname "$0")
RESOLVED_DIR=$(cd "$DIR" >/dev/null; pwd)
WORK_DIR=$RESOLVED_DIR/work
export TARGET_DIR="$WORK_DIR/target"
export PREFIX_DIR="$TARGET_DIR/usr"
export LV2_DIR="$PREFIX_DIR/lib/lv2"
export DATA_DIR="$RESOLVED_DIR/data"
CLEAN=false
CHECK_UPDATES=false

INTERACTIVE=false

while true
do
  case "$1" in
    --clean)
      CLEAN=true
      shift
      ;;
    --check-updates)
      CHECK_UPDATES=true
      shift
      ;;
    --interactive|-i)
      INTERACTIVE=true
      shift
      ;;
    *)
      break;;
  esac
done

setup

if [ "$INTERACTIVE" = true ]; then
  ENTRIES=()
  for d in "$DIR"/plugins/*/descriptor.yaml; do
    name=$(basename "$(dirname "$d")")
    ENTRIES+=("$name" "" OFF)
  done
  SELECTED=$(whiptail --title "Select plugins to build" \
    --checklist "Use space to select, enter to confirm:" \
    20 60 12 "${ENTRIES[@]}" 3>&1 1>&2 2>&3) || exit 0
  eval set -- $SELECTED
fi

if [ "$CHECK_UPDATES" = true ]; then
  PLUGIN_LIST=("$@")
  if [ ${#PLUGIN_LIST[@]} -eq 0 ]; then
    PLUGIN_LIST=($(ls "$DIR/plugins/"))
  fi

  UPDATES_AVAILABLE=0
  NOT_BUILT=0
  UP_TO_DATE=0
  CONFIG_CHANGED=0

  echo "=== Checking for updates ==="
  for PLUGIN in "${PLUGIN_LIST[@]}"; do
    DESC="$DIR/plugins/$PLUGIN/descriptor.yaml"
    if [ -f "$DESC" ]; then
      parse "$DESC"
      check_remote_update "$DESC"
    else
      printf "  %-30s no descriptor\n" "$PLUGIN"
    fi
  done

  echo ""
  echo "=== Summary ==="
  echo "Updates available: $UPDATES_AVAILABLE"
  echo "Config changed: $CONFIG_CHANGED"
  echo "Up to date: $UP_TO_DATE"
  echo "Not built: $NOT_BUILT"
  exit 0
fi

FAILED_PLUGINS=()
SUCCEEDED=0
for PLUGIN in "$@"; do
  DESC="$DIR/plugins/$PLUGIN/descriptor.yaml"
  if [ -f "$DESC" ]; then
    parse "$DESC"
    echo "Plugin: $PLUGIN"
    if ! check_dependencies; then
      FAILED_PLUGINS+=("$PLUGIN (missing dependencies)")
      continue
    fi
    if [ $CLEAN = true ]; then
      clean "$DESC"
    fi
    if ! download "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (download)")
      continue
    fi
    if is_up_to_date; then
      echo "=== Up to date: $NAME (skipping) ==="
      SUCCEEDED=$((SUCCEEDED + 1))
      continue
    fi
    prepare "$DESC"
    if ! build "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (build)")
      continue
    fi
    if ! install "$DESC"; then
      FAILED_PLUGINS+=("$PLUGIN (install)")
      continue
    fi
    if [ "$PLUGIN_TYPE" = "vst3" ]; then
      if ! generate_vst3_wrapper; then
        FAILED_PLUGINS+=("$PLUGIN (vst3 wrapper)")
        continue
      fi
    fi
    generate_modgui
    inject_description
    package
    save_build_sha
    SUCCEEDED=$((SUCCEEDED + 1))
  else
    echo "Plugin $PLUGIN doesn't have a descriptor"
    FAILED_PLUGINS+=("$PLUGIN (no descriptor)")
  fi
done

echo ""
echo "=== Summary ==="
echo "Succeeded: $SUCCEEDED"
echo "Failed: ${#FAILED_PLUGINS[@]}"
if [ ${#FAILED_PLUGINS[@]} -gt 0 ]; then
  echo ""
  echo "Failed plugins:"
  for p in "${FAILED_PLUGINS[@]}"; do
    echo "  - $p"
  done
fi
