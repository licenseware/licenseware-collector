// Fails when the translation dictionaries in index.html do not hold the same
// keys, or when a data-i18n key on the page has no string in one of them.
// Unused dictionary keys are listed but are not an error.
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const marker = "const translations = ";
const start = html.indexOf(marker);
const end = html.indexOf("\n      };", start);
if (start < 0 || end < 0) {
  throw new Error("index.html: translations dictionary not found");
}
const translations = vm.runInNewContext(
  `(${html.slice(start + marker.length, end + "\n      }".length)})`,
);

const used = new Set(
  [...html.matchAll(/data-i18n="([^"]+)"/gu)].map((match) => match[1]),
);
const langs = Object.keys(translations);
const problems = [];
for (const lang of langs) {
  for (const key of used) {
    if (!Object.hasOwn(translations[lang], key)) {
      problems.push(`${lang}: no string for data-i18n="${key}"`);
    }
  }
  for (const other of langs) {
    for (const key of Object.keys(translations[other])) {
      if (!Object.hasOwn(translations[lang], key)) {
        problems.push(`${lang}: missing "${key}", which ${other} has`);
      }
    }
  }
}

const unused = Object.keys(translations[langs[0]]).filter(
  (key) => !used.has(key),
);
if (unused.length > 0) {
  process.stdout.write(`i18n: unused keys: ${unused.join(", ")}\n`);
}
if (problems.length > 0) {
  process.stderr.write(`${problems.join("\n")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(
    `i18n: ${used.size} keys on the page, ${langs.join(" and ")} in sync\n`,
  );
}
