import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const [binaryPath, outputPath] = process.argv.slice(2);
if (!binaryPath || !outputPath || !process.env.VEASEL_BUILD_CC) {
  throw new Error("usage: node scripts/build-manifest.mjs <binary> <output> (VEASEL_BUILD_CC required)");
}

const binary = readFileSync(binaryPath);
const compiler = process.env.VEASEL_BUILD_CC;
const compilerVersion = execFileSync(compiler, ["--version"], { encoding: "utf8" })
  .split(/\r?\n/, 1)[0];
const manifest = {
  schema_version: 1,
  source_commit: process.env.VEASEL_BUILD_COMMIT ?? "unknown",
  v_compiler_commit: readFileSync(".v-version", "utf8").trim(),
  v_compiler_version: execFileSync("v", ["version"], { encoding: "utf8" }).trim(),
  c_compiler: compiler,
  c_compiler_version: compilerVersion,
  build_flags: process.env.VEASEL_BUILD_FLAGS ?? "unknown",
  target: `${process.platform}-${process.arch}`,
  runner: {
    os: process.env.VEASEL_RUNNER_OS ?? process.platform,
    architecture: process.env.VEASEL_RUNNER_ARCH ?? process.arch,
    image_os: process.env.ImageOS ?? null,
    image_version: process.env.ImageVersion ?? null,
  },
  binary: binaryPath.replaceAll("\\", "/").split("/").at(-1),
  binary_sha256: createHash("sha256").update(binary).digest("hex"),
};

const destination = resolve(outputPath);
if (dirname(destination) === resolve(".")) {
  throw new Error("build manifest must be written outside the repository root");
}
writeFileSync(destination, `${JSON.stringify(manifest, null, 2)}\n`, { flag: "wx" });
process.stdout.write(`${JSON.stringify(manifest)}\n`);
