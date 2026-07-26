{ lib }:
rec {
  quotePath = path: ''"${lib.escape [ "\\" "\"" ] (toString path)}"'';

  quotePaths = map quotePath;
}
