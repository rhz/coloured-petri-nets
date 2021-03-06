{-# LANGUAGE  QuasiQuotes #-}

import qualified System.Random as R
import Chromar

--- Agents
data Token = L { m :: Double }
           | B { c :: Double }
           | R { n :: Int }
           deriving (Eq, Show)


isL :: Token -> Bool
isL (L{}) = True
isL _     = False

isB :: Token -> Bool
isB (B{}) = True
isB _     = False


--- Rules
growth       = [rule| L{m=m}, B{c=c} --> L{m=m+1.0}, B{c=c-1.0} @c/m [c-1>0] |]
assimilation = [rule| L{m=m}, B{c=c} --> L{m=m}, B{c=c+1} @m [True] |]
leafCreation = [rule| R{n=n}         --> R{n=n+1}, L{m=0} @0.0001 [True] |]


--- Initial state
s = ms [L{m=0.01}, L{m=0.02}, B{c=0.3}, R{n=2}]


--- Observables
rosMass = Observable { name = "rosetteMass",
                       gen  = sumM m . select isL } 


carbon = Observable { name = "carbon",
                      gen  = sumM c . select isB }


nLeaves = Observable { name = "nLeaves",
                       gen  = countM . select isL }


model = Model { rules     = [growth, assimilation, leafCreation],
                initState = s }

--- run
main :: IO ()
main = run model nsteps observables where
  nsteps = 1000
  observables = [rosMass, carbon, nLeaves]
