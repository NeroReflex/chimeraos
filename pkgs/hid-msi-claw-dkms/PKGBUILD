_pkgname=hid-msi-claw
pkgname=$_pkgname-dkms
pkgver=0.0.2
pkgrel=1
pkgdesc='Linux kernel driver for MSI Claw device'
arch=('x86_64')
url='https://github.com'
license=('GPL2')
depends=('dkms')

#install=$_pkgname.install
source=(
		"Makefile"
		"dkms.conf"
		"hid-msi-claw.c")
sha256sums=(
		'SKIP'
		'SKIP'
		'SKIP'
)

#prepare() {
#  sed -e "s/@CFLGS@//" \
#      -e "s/@VERSION@/$pkgver/" \
#      -i "$srcdir/$_pkgname/dkms.conf"
#}

package() {
  install -Dm644 "$srcdir/dkms.conf" "$pkgdir/usr/src/$_pkgname-$pkgver/dkms.conf"
  install -Dm644 "$srcdir/Makefile" "$pkgdir/usr/src/$_pkgname-$pkgver/Makefile"
  install -Dm644 "$srcdir/hid-msi-claw.c" "$pkgdir/usr/src/$_pkgname-$pkgver/hid-msi-claw.c"

  #install -Dm644 "$srcdir/$_pkgname.conf" "$pkgdir/usr/lib/modprobe.d/$_pkgname.conf"
}

# vim:set et ts=2 sw=2 tw=79
