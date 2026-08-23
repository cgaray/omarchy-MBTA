// Scans QML files for `root.<name>` references that the file never declares.
// Inherited members from qs.Ui bases are allowlisted per root type.
"use strict"

const fs = require("fs")
const path = require("path")

const REPO = path.join(__dirname, "..")

// Members inherited from qs.Ui.Panel / qs.Ui.BarWidget roots, plus QML Item
// built-ins commonly referenced on root.
const BASE_MEMBERS = new Set([
  // qs.Ui.BarWidget
  "bar", "moduleName", "settings", "vertical", "barSize",
  "broadcast", "setting",
  // qs.Ui.Panel
  "ipcTarget", "manageIpc", "controller", "popoutSwitching", "popoutSwitchClosing",
  "opened", "barForeground", "open", "close", "closeForPopoutSwitch",
  "toggle", "switchPanel",
  // Qt Quick Item + Row/Column/Flow positioners
  "parent", "children", "width", "height", "visible", "anchors", "data",
  "resources", "implicitWidth", "implicitHeight", "x", "y", "z", "opacity",
  "rotation", "scale", "clip", "enabled", "state", "states", "transitions",
  "spacing", "padding", "leftPadding", "rightPadding", "topPadding", "bottomPadding"
])

function declaredNames(source) {
  const names = new Set()
  const patterns = [
    /^\s*(?:(?:readonly|required|default)\s+)*property\s+(?:var|bool|string|real|int|double|date|color|alias|QtObject|Item|Rectangle|Column|Row)\s+(\w+)/gm,
    /^\s*function\s+(\w+)\s*\(/gm,
    /^\s*signal\s+(\w+)\s*(\(|$)/gm,
    /^\s*id:\s*(\w+)\s*$/gm
  ]
  for (const re of patterns) {
    let m
    while ((m = re.exec(source)) !== null) names.add(m[1])
  }
  return names
}

function usedRootRefs(source) {
  const refs = new Set()
  const re = /\broot\.(\w+)/g
  let m
  while ((m = re.exec(source)) !== null) refs.add(m[1])
  return refs
}

let failures = 0
const qmlFiles = fs.readdirSync(REPO).filter(f => f.endsWith(".qml"))

for (const file of qmlFiles) {
  const source = fs.readFileSync(path.join(REPO, file), "utf8")

  // Comments carry contract notes but must not create fake declarations or uses.
  const stripped = source.replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "")
  const declared = declaredNames(stripped)
  for (const ref of usedRootRefs(stripped)) {
    if (declared.has(ref) || BASE_MEMBERS.has(ref)) continue
    failures++
    console.log(`FAIL  ${file}: undeclared root.${ref}`)
  }

  // Every delegate component referenced by name must exist on disk.
  const loaderMatches = stripped.match(/Qt\.resolvedUrl\("([^"]+)"\)/g) || []
  for (const match of loaderMatches) {
    const target = match.match(/"([^"]+)"/)[1]
    if (!fs.existsSync(path.join(REPO, target))) {
      failures++
      console.log(`FAIL  ${file}: Loader target missing: ${target}`)
    }
  }
}

if (failures === 0) {
  console.log(`qml refs ok (${qmlFiles.length} files: ${qmlFiles.join(", ")})`)
} else {
  console.log(`${failures} reference failure(s)`)
  process.exit(1)
}
