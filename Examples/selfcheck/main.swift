// Deliberately crashes so macOS's own crash reporter writes a REAL .ips,
// which coroner then ingests, symbolicates against the dSYM built next to it,
// and crosses with git history. Install sanity check: `make selfcheck`.
func boom() -> Int {
    let p: UnsafeMutablePointer<Int>? = UnsafeMutablePointer(bitPattern: 0x1)
    return p!.pointee   // EXC_BAD_ACCESS — never returns
}

let n = boom()
print("unreachable \(n)")
