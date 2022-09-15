from opcodes import AND, SHL
from rule import Rule
from z3 import BitVec

"""
Rule:
AND(SHL(A,X), SHL(A,Y)) -> SHL(A, AND(X,Y))
"""

rule = Rule()

n_bits = 128

# Input vars
X = BitVec('X', n_bits)
Y = BitVec('Y', n_bits)
A = BitVec('A', n_bits)

# Non optimized result
nonopt = AND(SHL(A,X), SHL(A,Y))

# Optimized result
opt = SHL(A, AND(X,Y))

rule.check(nonopt, opt)
