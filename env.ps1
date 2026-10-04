$ErrorActionPreference = 'Stop'

# Shared build environment for the vweb module.
#
# Always source this before building. The two things it decides are which V tree
# the build resolves `vlib` from and which C compiler links the result, and both
# have cost a session to get wrong.
#
#   VEXE, VEXEROOT - the V compiler *and the tree it belongs to*. These are one
#             decision, not two: a compiler binary resolves `vlib` from its own
#             directory, and there is no VROOT override in this version, so
#             pointing VEXE somewhere else than VEXEROOT silently builds against a
#             different standard library.
#
#             There are two V trees on this machine and vweb needs different halves
#             of each, which is worth stating plainly rather than discovering again:
#
#               C:\Users\MR\v                 compiler 9d34aa2, vlib/net/html is the
#                                            OLD tree -- no `is_element`, no
#                                            tree.v, no sibling links.
#               C:\Users\MR\Projects\v       compiler 67f4642, vlib/net/html is the
#                                            REWRITTEN tree that ARCHITECTURE.md 6
#                                            depends on -- but `vtext`, which this
#                                            engine is built on, does not compile
#                                            under it ("field `selectors` of struct
#                                            `vtext.ShapedGlyph` is immutable" in
#                                            joining.v:279), and vtext is a separate
#                                            repository with uncommitted work in it
#                                            that is not ours to change.
#
#             So the build uses the old tree, and engine/tree holds the one
#             predicate the old tree lacks. That duplication is deliberate and is
#             deleted the moment both halves come from one tree.
#
#             Its commit hash moves under you: `v.mod` reports 0.5.2 for every
#             build, so the version string identifies nothing. Ask the binary
#             (`v version`) rather than trusting this comment. Clear the build cache
#             after changing any of this, or a cached result from the other tree will
#             be reported as this one's.
#   CC      - tcc, always explicitly. gcc is not a fallback here: scoop's gcc
#             cannot resolve ws2_32, so anything that drops off tcc dies with an
#             unrelated-looking "undefined reference to __imp_connect".
#             `-stats` also breaks the tcc link.
#   TMPDIR  - a private build directory. V puts its C build directory at
#             <temp>/v_<uid>, which is shared with *every* V build on this
#             machine; several other sessions were running V while this one was.
#             The tell is a suite that is green alone and red in a full run, with
#             "failed to create C build directory" in the output. It is built
#             under the user profile rather than under os.temp_dir(), because
#             nesting a private directory inside vtmp_dir() would reproduce the
#             collision it exists to prevent.
$env:VEXE = "C:\Users\MR\v\v.exe"
$env:VEXEROOT = "C:\Users\MR\v"
$env:VMODULES = "C:\Users\MR\Projects"
$env:CC = "tcc"
$env:TMPDIR = "C:\Users\MR\AppData\Local\Temp\opencode\vweb_build"

if (-not (Test-Path -LiteralPath $env:TMPDIR)) {
	New-Item -ItemType Directory -Path $env:TMPDIR -Force | Out-Null
}

# VMODULES holds both this module and vtext so `import vtext` resolves without
# `v install`. vpm cannot install vtext at all: its v.mod names a repo_url that
# does not exist, so it fails with "failed to retrieve metadata". There is a
# junction at ~/.vmodules/vtext pointing at the checkout instead.
