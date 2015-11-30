import qualified Data.Map as Map
import qualified System.Random as R
import Data.Maybe (fromMaybe, fromJust)
import Data.List (find, findIndex)
import System.Environment (getArgs)

-- TODO: make these data types parametric on Token

type Multiset = [(Token, Int)]
data Rxn = Rxn { lhs :: Multiset,
                 rhs :: Multiset,
                 rate :: Double }
  deriving (Eq, Show)
type Rule = Multiset -> [Rxn]
type State = (Multiset, Double, Int) -- (mixture, time, num of steps)

-- TODO: rewrite this, it's unnecessary to work with Maps
frequencies :: (Ord a, Num b) => [a] -> Map.Map a b
frequencies xs = foldl (flip $ Map.alter (\v -> Just $ fromMaybe 0 v + 1)) Map.empty xs

ms :: [Token] -> [(Token, Int)]
ms = Map.toList . frequencies

diff :: Multiset -> Multiset -> Multiset
diff [] ys = []
diff ((x,n):xs) ys = sub $ find (\(y,_) -> x == y) ys
  where sub (Just (y,m)) | n-m > 0 = (x,n-m):(diff xs ys)
                         | otherwise = diff xs ys
        sub Nothing = (x,n):(diff xs ys)

plus :: Multiset -> Multiset -> Multiset
plus [] ys = ys
plus ((x,n):xs) ys = add $ findAndRemove [] (\(y,_) -> x == y) ys
  where add (Just (y,m), ys') = (x,n+m):(plus xs ys')
        add (Nothing, _) = (x,n):(plus xs ys)

findAndRemove :: [a] -> (a -> Bool) -> [a] -> (Maybe a, [a])
findAndRemove acc _ [] = (Nothing, reverse acc)
findAndRemove acc p (x:xs) | p x = (Just x, (reverse acc) ++ xs)
                           | otherwise = findAndRemove (x:acc) p xs

apply :: Rxn -> Multiset -> Multiset
apply rxn mix = mix `diff` (lhs rxn) `plus` (rhs rxn)

selectRxn :: Double -> Double -> [Rxn] -> Rxn
selectRxn _ _ [] = error "deadlock"
selectRxn _ _ [rxn] = rxn
selectRxn acc n (rxn:rxns) | n < acc' = rxn
                           | otherwise = selectRxn acc' n rxns
  where acc' = acc + (rate rxn)

sample :: R.StdGen -> [Rxn] -> (Rxn, Double, R.StdGen)
sample gen rxns = (selectRxn 0.0 b rxns,  dt, g2)
  where totalProp = sum $ map rate rxns
        (a, g1) = R.randomR (0.0, 1.0) gen
        (b, g2) = R.randomR (0.0, totalProp) g1
        dt = log (1.0/a) / totalProp

step :: [Rule] -> (R.StdGen, State) -> (R.StdGen, State)
step rules (gen, (mix, t, n)) = (gen', (mix', t+dt, n+1))
  where rxns = concatMap (\r -> r mix) rules
        (rxn, dt, gen') = sample gen rxns
        mix' = apply rxn mix

simulate :: R.StdGen -> [Rule] -> Multiset -> [State]
simulate gen rules init =
  map snd $ iterate (step rules) (gen, (init, 0.0, 0))

printTrajectory :: [State] -> IO ()
printTrajectory states = mapM_ printMixture states
  where printMixture :: State -> IO ()
        printMixture (m,t,n) =
          putStrLn $ unwords [show t, show n, show m]


-- Model

data Token = L Double Int -- mass and index
           | B Double -- carbon
           | R Int -- age
  deriving (Eq, Show, Ord)

index :: Token -> Int
index (L m i) = i
index _ = error "token is not of type L"

mass :: Token -> Double
mass (L m i) = m
mass _ = error "token is not of type L"

carbon :: Token -> Double
carbon (B c) = c
carbon _ = error "token is not of type B"

gmax :: Double
gmax = 1.0

d :: Int -> Double
d 0 = 1
d 1 = 2

-- TODO: use quasi-quotes to make the definition of rules simpler

-- L m i, B c -> L (m+1) i, B (c-1)
grow :: Multiset -> [Rxn]
grow mix = [ rxn m i c k n | (L m i, k) <- mix
                           , (B c, n) <- mix ]
  where rxn :: Double -> Int -> Double -> Int -> Int -> Rxn
        rxn m i c k n =
          Rxn { lhs = ms [L m i, B c]
              , rhs = ms [L (m+1) i, B (c-1)]
              , rate = gmax * d(i) * c *
                       (fromIntegral k) * (fromIntegral n) }

-- R age -> R (age+1), L m0 age
m0 :: Double
m0 = 0.0

createLeaf :: Multiset -> [Rxn]
createLeaf mix = [ rxn age n | (R age, n) <- mix ]
  where rxn :: Int -> Int -> Rxn
        rxn age n = Rxn { lhs = ms [R age]
                        , rhs = ms [R (age+1), L m0 age]
                        , rate = n }

-- TODO: add the other rules

main :: IO ()
main = do
  gen <- R.getStdGen
  args <- getArgs
  let n = (read $ head args) :: Int
  let init = ms [B 100, L 0 0, L 0 1]
  let traj = simulate gen rules init
  printTrajectory $ take n traj
  where rules :: [Rule]
        rules = [grow]