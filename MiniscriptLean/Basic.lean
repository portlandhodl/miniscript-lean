namespace Miniscript

/-- Miniscript base types: B (base), V (verify), K (key), W (wrapped). -/
inductive BaseTy where
  | B   -- base: consumes top of stack, produces one unit
  | V   -- verify: consumes top of stack, produces nothing (aborts on failure)
  | K   -- key: a public key input
  | W   -- wrapped: produces one unit on stack
  deriving Repr, DecidableEq

example : BaseTy.B ≠ BaseTy.V := by decide

end Miniscript
