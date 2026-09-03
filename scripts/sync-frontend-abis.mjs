import { readFile, writeFile } from "node:fs/promises";

const mappings = [
  ["out/CompleteSetInternalizationHook.sol/CompleteSetInternalizationHook.json", "frontend/src/abi/CompleteSetInternalizationHook.json"],
  ["out/CompleteSetQuoter.sol/CompleteSetQuoter.json", "frontend/src/abi/CompleteSetQuoter.json"],
];

for (const [artifactPath, abiPath] of mappings) {
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  await writeFile(abiPath, `${JSON.stringify(artifact.abi, null, 2)}\n`);
}
