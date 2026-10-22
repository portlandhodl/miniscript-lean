import Lake
open Lake DSL

package «miniscript-lean» where
  -- no external dependencies: dependency-free skeleton

@[default_target]
lean_lib MiniscriptLean where
  -- library target rooted at MiniscriptLean.lean

@[default_target]
lean_exe «miniscript-lean» where
  root := `Main
