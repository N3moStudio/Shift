Shift appearance artwork

Settings > Appearance chooses Glacier, Afterhours or Porcelain independently
from Settings > Appearance > App Icon. Each icon family has Default, Dark and
Tinted choices. Glacier Default is the primary icon.

SVG files preserve the approved vector designs; PNG files are opaque 1024x1024
exports. iOS applies the outer Home Screen icon mask. Do not bake rounded outer
corners or transparency into these images.

Locus/Resources/Assets.xcassets contains nine named icon sets. Each includes
any, dark and grayscale tinted variants for Xcode's asset compiler. The native
Home Screen tint is chosen by the user in iOS, independently from Shift's style.
Locus/Resources/IconPreviews supplies the nine in-app choice thumbnails.

Portable xtool builds can package these as nine manually selectable PNG icons
using CFBundleIcons and CFBundleIcons~ipad. They do not compile Assets.car, so
custom automatic dark/tinted artwork requires an Xcode build. The Dark and
Tinted choices remain explicitly selectable in the portable build.

The navigation, orbit and move-up-right symbols derive from Lucide; see
LICENSE-Lucide.txt. Other appearance composition is original Shift artwork.
