// SVG → multi-size PNG → ICO
const sharp = require('sharp');
const toIco = require('png-to-ico').default;
const fs = require('fs');

(async () => {
  const svg = fs.readFileSync('D:/claude-windows-debug/claude-logo.svg');
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const pngs = [];
  for (const size of sizes) {
    // Add transparent padding so the star isn't clipped at edges
    const png = await sharp(svg, { density: 384 })
      .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer();
    pngs.push(png);
  }
  const ico = await toIco(pngs);
  fs.writeFileSync('D:/claude-windows-debug/claude-logo.ico', ico);
  console.log('ICO written:', ico.length, 'bytes for sizes', sizes.join('/'));
})();
