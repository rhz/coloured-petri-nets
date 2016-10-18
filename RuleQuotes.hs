module Ext where

import Language.Haskell.TH
import Language.Haskell.Meta.Parse
import Language.Haskell.TH.Quote
import Language.Haskell.TH.Syntax
import Data.Set (Set)
import qualified Data.Set as Set
import Text.ParserCombinators.Parsec
import Language.Haskell.Exts.Pretty
import Data.List
import RuleParser


type FieldProd = (FieldPat, [Exp], Set Name)


rule :: QuasiQuoter
rule = QuasiQuoter { quoteExp  = ruleQuoter,
                     quotePat  = undefined,
                     quoteDec  = undefined,
                     quoteType = undefined }


--- pure action
tFieldPat :: Set Name -> Name -> FieldExp -> FieldProd
tFieldPat names freshNm (nm, VarE pnm) =
  case (Set.member pnm names) of
    False -> ((nm, VarP pnm), [], Set.fromList [pnm])
    True ->
      ( (nm, VarP freshNm)
      , [UInfixE (VarE freshNm) (VarE $ mkName "==") (VarE pnm)]
      , Set.empty )
tFieldPat name freshNm (nm, exp) =
  ( (nm, VarP freshNm)
  , [UInfixE (VarE freshNm) (VarE $ mkName "==") exp]
  , Set.empty)


--- monadic action
qtFieldPat :: Set Name -> FieldExp -> Q FieldProd
qtFieldPat names fexp@(nm, exp) = do
  fn <- newName (showName nm)
  return $ tFieldPat names fn fexp


mkGuardExp :: [[Exp]] -> Exp
mkGuardExp expss = AppE andFunc (ListE exps) where
  andFunc = VarE (mkName "and")
  exps    = concat expss


mkAgentExps :: Q [FieldProd] -> Q ([FieldPat], Exp, Set Name)
mkAgentExps qfps = do
  fps <- qfps
  let (fpats, exprss, sets) = unzip3 fps
  let guardExp = mkGuardExp exprss
  let sn = Set.unions sets
  return $ (fpats, guardExp, sn)


mkPatStmt :: Name -> [FieldPat] -> Stmt
mkPatStmt nm fpats = BindS pat (VarE $ mkName "s") where
  pat = TupP [RecP nm fpats, WildP]


mkGuardStmt :: Exp -> Stmt
mkGuardStmt = NoBindS 


mkAgentStmts :: Name -> Q ([FieldPat], Exp, Set Name) -> Q ([Stmt], Set Name)
mkAgentStmts nm qexps = do
  (fpats, gExp, sn) <- qexps
  let patStmt = mkPatStmt nm fpats
  let guardStmt = mkGuardStmt gExp
  return $ ([patStmt, guardStmt], sn)


tAgentPat :: Set Name -> Exp -> Q ([Stmt], Set Name)
tAgentPat sn (RecConE nm fexps) = mkAgentStmts nm qexps where
  qfps  = mapM (qtFieldPat sn) fexps
  qexps = mkAgentExps qfps


mkLhsStmts :: Set Name -> [Stmt] -> [Exp] -> Q [Stmt]
mkLhsStmts sn allStmts [] = return $ allStmts
mkLhsStmts sn allStmts (exp:exps) = do
  (stmts, sn') <- tAgentPat sn exp
  mkLhsStmts (Set.union sn sn') (allStmts ++ stmts) exps


mkLhs :: [Exp] -> Q [Stmt]
mkLhs exps = mkLhsStmts Set.empty [] exps


mkLhsExp :: Q Exp
mkLhsExp = do
  state <- newName "s"
  return $
    LamE
      [VarP state]
      (UInfixE (VarE $ mkName "s") (VarE $ mkName "==") (LitE (IntegerL 1)))


foo :: Set Name -> Exp -> Q Exp
foo sn exp = do
  (stmts, sn) <- tAgentPat sn exp
  stringE (show stmts)


foo' :: [String] -> Q Exp
foo' rs = do
  let exprs = createExps rs
  stmts <- mkLhs exprs
  stringE (show stmts)



isFluent :: Info -> Bool
isFluent (VarI m t _ _) =
  case t of
    (AppT (ConT tnm) _) -> isSuffixOf "Fluent" (show tnm)
    _ -> False
isFluent _ = False


mkFApp :: Name -> Exp
mkFApp nm = ParensE (AppE (AppE (VarE $ mkName "at")  (VarE nm)) (VarE $ mkName "t"))


tStmt :: Stmt -> Q Stmt
tStmt (BindS p e) = do
  te <- tExp e
  return $ (BindS p te)
tStmt (NoBindS e) = do
  te <- tExp e
  return $ (NoBindS te)


tMExp :: Maybe Exp -> Q (Maybe Exp)
tMExp (Just e) = do
  te <- tExp e
  return (Just te)
tMExp Nothing  = return Nothing


--- there's probably a better way of doing this
tExp :: Exp -> Q Exp
tExp var@(VarE nm) = do
  info <- reify nm
  if (isFluent info)
    then return $ mkFApp nm
    else return var
tExp (AppE e1 e2) = do
  te1 <- tExp e1
  te2 <- tExp e2
  return $ AppE te1 te2
tExp (TupE exps) = do
  texps <- mapM tExp exps
  return $ TupE texps
tExp (ListE exps) = do
  texps <- mapM tExp exps
  return $ ListE texps
tExp (UInfixE e1 e2 e3) = do
  te1 <- tExp e1
  te2 <- tExp e2
  te3 <- tExp e3
  return $ (UInfixE te1 te2 te3)
tExp (ParensE e) = do
  te <- tExp e
  return $ (ParensE te)
tExp (LamE pats e) = do
  te <- tExp e
  return $ (LamE pats te)
tExp (CompE stmts) = do
  tstmts <- mapM tStmt stmts
  return $ (CompE tstmts)
tExp (InfixE me1 e me2) = do
  tme1 <- tMExp me1
  te   <- tExp e
  tme2 <- tMExp me2
  return $ (InfixE tme1 te tme2)
tExp (LitE lit) = return $ (LitE lit)
tExp _ = undefined


tuplify :: Name -> Exp -> Exp -> Exp
tuplify s lhs r = TupE [lhs, VarE s, r]


mkRateExp :: Name -> Exp -> Exp -> Exp
mkRateExp s lhs r = AppE (VarE $ mkName "fullRate") args where
  args = tuplify s lhs r


mkReturnStmt :: Exp -> Stmt
mkReturnStmt = NoBindS


mkRxnExp :: Name -> SRule -> Exp
mkRxnExp s r = RecConE (mkName "Rxn") fields where
  lhsSym  = mkName "lhs"
  rhsSym  = mkName "rhs"
  rateSym = mkName "rate"
  lexps'  = AppE (VarE $ mkName "ms") (ListE $ lexps r)
  rexps'  = AppE (VarE $ mkName "ms") (ListE $ rexps r)
  rateExp = mkRateExp s lexps' (rate r) 
  fields  = [ (lhsSym , lexps'),
              (rhsSym , rexps'),
              (rateSym, rateExp)
            ]


mkCompStmts :: Name -> SRule -> Q [Stmt]
mkCompStmts s r = do
  let rxnExp = mkRxnExp s r
  let retStmt   = mkReturnStmt rxnExp
  let guardStmt = NoBindS (cond r)
  patStmts  <- mkLhs (lexps r)
  return $ patStmts ++ [guardStmt, retStmt]


ruleQuoter' :: SRule -> Q Exp
ruleQuoter' r = do
  state <- newName "s"
  time  <- newName "t"
  stmts <- mkCompStmts state r
  return $ LamE [VarP state, VarP time] (CompE stmts)


fluentTransform :: SRule -> Q SRule
fluentTransform (SRule { lexps = les
                       , rexps = res
                       , rate = r
                       , cond = c
                       }) = do
  re <- tExp r
  ce <- tExp c
  return $ SRule {lexps = les, rexps = res, rate = re, cond = ce}


ruleQuoter :: String -> Q Exp
ruleQuoter s = case parse parseRule "" s of
  Left err  -> error (show err)
  Right r   -> do
    sr <- fluentTransform r
    ruleQuoter' sr
