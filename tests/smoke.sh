#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/To SVG.app/Contents/MacOS/ToSVG"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/art & shape.eps" <<'PS'
%!PS-Adobe-3.0 EPSF-3.0
%%BoundingBox: 0 0 200 100
1 0 0 setrgbcolor
10 10 moveto 190 10 lineto 100 90 lineto closepath fill
showpage
PS
"$APP" --convert "$TEST_DIR/art & shape.eps"
"$APP" --convert "$TEST_DIR/art & shape.eps"
test -s "$TEST_DIR/art & shape.svg"
test -s "$TEST_DIR/art & shape (2).svg"
gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite "-sOutputFile=$TEST_DIR/multi.pdf" "$TEST_DIR/art & shape.eps" "$TEST_DIR/art & shape.eps"
"$APP" --convert "$TEST_DIR/multi.pdf"
test -s "$TEST_DIR/multi-page-1.svg"
test -s "$TEST_DIR/multi-page-2.svg"
cp "$TEST_DIR/multi.pdf" "$TEST_DIR/compatible.ai"
"$APP" --convert "$TEST_DIR/compatible.ai"
test -s "$TEST_DIR/compatible-page-2.svg"
cp "$TEST_DIR/art & shape.eps" "$TEST_DIR/legacy.ai"
"$APP" --convert "$TEST_DIR/legacy.ai"
test -s "$TEST_DIR/legacy.svg"
printf 'invalid' > "$TEST_DIR/unsupported.ai"
if "$APP" --convert "$TEST_DIR/unsupported.ai"; then exit 1; fi
test ! -e "$TEST_DIR/unsupported.svg"
python3 - "$TEST_DIR" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
for path in pathlib.Path(sys.argv[1]).glob('*.svg'):
    root = ET.parse(path).getroot()
    assert root.tag == '{http://www.w3.org/2000/svg}svg'
    assert root.findall('.//{http://www.w3.org/2000/svg}path'), path
    assert not root.findall('.//{http://www.w3.org/2000/svg}image'), path
PY
printf 'All conversion smoke tests passed.\n'
