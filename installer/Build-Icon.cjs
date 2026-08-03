const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const projectRoot = path.resolve(__dirname, '..');
const sourcePath = path.join(projectRoot, 'assets', 'CCStatus.png');
const icoPath = path.join(projectRoot, 'assets', 'CCStatus.ico');
const previewPath = path.join(projectRoot, 'assets', 'CCStatus.png');
const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

async function main() {
  const source = fs.readFileSync(sourcePath);
  const images = [];
  for (const size of sizes) {
    images.push(size === 256 ? source : await sharp(source).resize(size, size).png().toBuffer());
  }

  const headerSize = 6 + sizes.length * 16;
  const header = Buffer.alloc(headerSize);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = headerSize;
  images.forEach((image, index) => {
    const size = sizes[index];
    const entry = 6 + index * 16;
    header.writeUInt8(size === 256 ? 0 : size, entry);
    header.writeUInt8(size === 256 ? 0 : size, entry + 1);
    header.writeUInt8(0, entry + 2);
    header.writeUInt8(0, entry + 3);
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(image.length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += image.length;
  });

  fs.writeFileSync(icoPath, Buffer.concat([header, ...images]));
  fs.writeFileSync(previewPath, source);
  process.stdout.write(`ICO=${icoPath}\nPREVIEW=${previewPath}\n`);
}

main().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
