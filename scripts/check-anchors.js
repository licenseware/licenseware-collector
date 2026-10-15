// Fails when an in-page link points nowhere, an id is used twice, or an
// anchor the site has published stops resolving.
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");

// Anchors that bookmarks, the retired install.sh stub and other pages use.
// Add an anchor here before creating it; never remove one.
const PUBLISHED = [
  "overview",
  "compatibility",
  "network",
  "system",
  "downloads",
  "installation",
  "proxy",
  "custom-ca",
  "uninstall",
  "endpoints",
  "process",
  "catalogs",
  "paths",
  "commands",
  "logs",
  "licence-agreement",
  "single-machine",
  "intune",
  "macos-mdm",
  "linux-fleets",
  "golden-images",
  "settings",
  "day2",
  "upgrading",
  "troubleshooting",
  "ts-status",
  "ts-windows",
  "ts-macos",
  "ts-linux",
  "ts-network",
  "ts-app",
  "glossary",
];

const ids = [...html.matchAll(/\sid="([^"]+)"/gu)].map((match) => match[1]);
const seen = new Set();
const problems = [];
for (const id of ids) {
  if (seen.has(id)) {
    problems.push(`duplicate id="${id}"`);
  }
  seen.add(id);
}
const links = [...html.matchAll(/href=\\?"#([^"\\]+)\\?"/gu)].map(
  (match) => match[1],
);
for (const target of new Set(links)) {
  if (!seen.has(target)) {
    problems.push(`href="#${target}" has no element`);
  }
}
for (const id of PUBLISHED) {
  if (!seen.has(id)) {
    problems.push(`published anchor #${id} is gone`);
  }
}

if (problems.length > 0) {
  process.stderr.write(`${problems.join("\n")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(
    `anchors: ${seen.size} ids, ${links.length} links, ${PUBLISHED.length} published anchors OK\n`,
  );
}
