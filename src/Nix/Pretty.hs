{-# language CPP #-}
{-# language AllowAmbiguousTypes #-}

{-# options_ghc -fno-warn-name-shadowing #-}


module Nix.Pretty where

import           Prelude                  hiding ( toList, group )
import           Control.Monad.Free             ( Free(Free) )
import           Data.Fix                       ( Fix(..)
                                                , foldFix )
import           Data.HashMap.Lazy              ( toList )
import qualified Data.HashMap.Lazy             as M
import qualified Data.HashSet                  as HashSet
import qualified Data.List.NonEmpty            as NE
import           Data.Text                      ( replace
                                                , strip
                                                )
import qualified Data.Text                     as Text
import           Prettyprinter           hiding ( list )
import           Nix.Atoms
import           Nix.Cited
import           Nix.Expr.Types
import           Nix.Expr.Types.Annotated
import           Nix.Expr.Strings
import           Nix.Normal
import           Nix.Parser
import           Nix.String
import           Nix.Thunk
import           Nix.Value

-- | This type represents a pretty printed nix expression
-- together with some information about the expression.
data NixDoc ann = NixDoc
  { -- | The rendered expression, without any parentheses.
    withoutParens    :: Doc ann

    -- | The root operator is the operator at the root of
    -- the expression tree. For example, in '(a * b) + c', '+' would be the root
    -- operator. It is needed to determine if we need to wrap the expression in
    -- parentheses.
  , rootOp :: OperatorInfo
  , wasPath :: Bool -- This is needed so that when a path is used in a selector path
                    -- we can add brackets appropriately
  }

mkNixDoc :: OperatorInfo -> Doc ann -> NixDoc ann
mkNixDoc o d = NixDoc { withoutParens = d, rootOp = o, wasPath = False }

-- | A simple expression is never wrapped in parentheses. The expression
--   behaves as if its root operator had a precedence higher than all
--   other operators (including function application).
simpleExpr :: Doc ann -> NixDoc ann
simpleExpr = mkNixDoc $ OperatorInfo minBound NAssocNone "simple expr"

pathExpr :: Doc ann -> NixDoc ann
pathExpr d = (simpleExpr d) { wasPath = True }

-- | An expression that behaves as if its root operator had a precedence lower
--   than all other operators. That ensures that the expression is wrapped in
--   parentheses in almost always, but it's still rendered without parentheses
--   in cases where parentheses are never required (such as in the LHS of a
--   binding).
leastPrecedence :: Doc ann -> NixDoc ann
leastPrecedence =
  mkNixDoc (OperatorInfo maxBound NAssocNone "least precedence")

appOp :: OperatorInfo
appOp = getBinaryOperator NApp

appOpNonAssoc :: OperatorInfo
appOpNonAssoc = (getBinaryOperator NApp) { associativity = NAssocNone }

selectOp :: OperatorInfo
selectOp = getSpecialOperator NSelectOp

hasAttrOp :: OperatorInfo
hasAttrOp = getSpecialOperator NHasAttrOp

wrapParens :: OperatorInfo -> NixDoc ann -> Doc ann
wrapParens op sub =
  bool
    (\ a -> "(" <> a <> ")")
    id
    (   precedence (rootOp sub)   <  precedence op
    || (precedence (rootOp sub)   == precedence op
        && associativity (rootOp sub) == associativity op
        && associativity op /= NAssocNone)
    )
    (withoutParens sub)

-- Used in the selector case to print a path in a selector as
-- "${./abc}"
wrapPath :: OperatorInfo -> NixDoc ann -> Doc ann
wrapPath op sub =
  bool
    (wrapParens op sub)
    ("\"${" <> withoutParens sub <> "}\"")
    (wasPath sub)

prettyString :: NString (NixDoc ann) -> Doc ann
prettyString (DoubleQuoted parts) = "\"" <> foldMap prettyPart parts <> "\""
 where
  -- It serializes Text -> String, because the helper code is done for String,
  -- please, can someone break that code.
  prettyPart (Plain t)      = pretty . foldMap escape . toString $ t
  prettyPart EscapedNewline = "''\\n"
  prettyPart (Antiquoted r) = "${" <> withoutParens r <> "}"
  escape '"' = "\\\""
  escape x   =
    maybe
      (one x)
      (('\\' :) . one)
      (toEscapeCode x)
prettyString (Indented _ parts) = group $ nest 2 $ vcat
  ["''", content, "''"]
 where
  content = vsep . fmap prettyLine . stripLastIfEmpty . splitLines $ parts
  stripLastIfEmpty :: [[Antiquoted Text r]] -> [[Antiquoted Text r]]
  stripLastIfEmpty = filter flt
   where
    flt :: [Antiquoted Text r] -> Bool
    flt [Plain t] | Text.null (strip t) = False
    flt _ = True

  prettyLine = hcat . fmap prettyPart
  prettyPart (Plain t) =
    pretty . replace "${" "''${" . replace "''" "'''" $ t
  prettyPart EscapedNewline = "\\n"
  prettyPart (Antiquoted r) = "${" <> withoutParens r <> "}"

prettyVarName :: VarName -> Doc ann
prettyVarName = pretty @Text . coerce

prettyParams :: Params (NixDoc ann) -> Doc ann
prettyParams (Param n           ) = prettyVarName n
prettyParams (ParamSet mname variadic pset) =
  prettyParamSet variadic pset <>
     toDoc `whenJust` mname
 where
  toDoc :: VarName -> Doc ann
  toDoc (coerce -> name) =
    ("@" <> pretty name) `whenFalse` Text.null name

prettyParamSet :: Variadic -> ParamSet (NixDoc ann) -> Doc ann
prettyParamSet variadic args =
  encloseSep
    "{ "
    (align " }")
    sep
    (fmap prettySetArg args <> one "..." `whenTrue` (variadic == Variadic))
 where
  prettySetArg (n, maybeDef) =
    maybe
      varName
      (\x -> varName <> " ? " <> withoutParens x)
      maybeDef
   where
    varName = prettyVarName n
  sep            = align ", "

prettyBind :: Binding (NixDoc ann) -> Doc ann
prettyBind (NamedVar n v _p) =
  prettySelector n <> " = " <> withoutParens v <> ";"
prettyBind (Inherit s ns _p) =
  "inherit " <> scope <> align (fillSep $ prettyVarName <$> ns) <> ";"
  where
    scope =
      ((<> " ") . parens . withoutParens) `whenJust` s

prettyKeyName :: NKeyName (NixDoc ann) -> Doc ann
prettyKeyName (StaticKey key) =
  bool
    "\"\""
    (bool
      varName
      ("\"" <> varName <> "\"")
      (HashSet.member key reservedNames)
    )
    (not $ Text.null $ coerce key)
 where
  varName = prettyVarName key
prettyKeyName (DynamicKey key) =
  runAntiquoted
    (DoubleQuoted $ one $ Plain "\n")
    prettyString
    (\ x -> "${" <> withoutParens x <> "}")
    key

prettySelector :: NAttrPath (NixDoc ann) -> Doc ann
prettySelector = hcat . punctuate "." . fmap prettyKeyName . NE.toList

prettyAtom :: NAtom -> NixDoc ann
prettyAtom = simpleExpr . pretty . atomText

prettyNix :: NExpr -> Doc ann
prettyNix = withoutParens . foldFix exprFNixDoc

prettyOriginExpr
  :: forall t f m ann
   . HasCitations1 m (NValue t f m) f
  => NExprLocF (Maybe (NValue t f m))
  -> Doc ann
prettyOriginExpr = withoutParens . go
 where
  go = exprFNixDoc . stripAnnF . fmap render
   where
    render :: Maybe (NValue t f m) -> NixDoc ann
    render Nothing = simpleExpr "_"
    render (Just (Free (reverse . citations @m -> p:_))) = go (_originExpr p)
    render _       = simpleExpr "?"
      -- render (Just (NValue (citations -> ps))) =
          -- simpleExpr $ foldr ((\x y -> vsep [x, y]) . parens . indent 2 . withoutParens
          --                           . go . originExpr)
          --     mempty (reverse ps)

exprFNixDoc :: NExprF (NixDoc ann) -> NixDoc ann
exprFNixDoc = \case
  NConstant atom -> prettyAtom atom
  NStr      str  -> simpleExpr $ prettyString str
  NList xs ->
    prettyContainer "[" (wrapParens appOpNonAssoc) "]" xs
  NSet NonRecursive xs ->
    prettyContainer "{" prettyBind "}" xs
  NSet Recursive xs ->
    prettyContainer "rec {" prettyBind "}" xs
  NAbs args body ->
    leastPrecedence $
      nest 2 $
        vsep
          [ prettyParams args <> ":"
          , withoutParens body
          ]
  NBinary NApp fun arg ->
    mkNixDoc appOp (wrapParens appOp fun <> " " <> wrapParens appOpNonAssoc arg)
  NBinary op r1 r2 ->
    mkNixDoc
      opInfo $
      hsep
        [ f NAssocLeft r1
        , pretty $ operatorName opInfo
        , f NAssocRight r2
        ]
   where
    opInfo = getBinaryOperator op
    f :: NAssoc -> NixDoc ann1 -> Doc ann1
    f x =
      wrapParens
        $ bool
            opInfo
            (opInfo { associativity = NAssocNone })
            (associativity opInfo /= x)
  NUnary op r1 ->
    mkNixDoc
      opInfo $
      pretty (operatorName opInfo) <> wrapParens opInfo r1
   where
    opInfo = getUnaryOperator op
  NSelect o r' attr ->
    maybe
      (mkNixDoc selectOp)
      (const leastPrecedence)
      o
      $ wrapPath selectOp r <> "." <> prettySelector attr <> ordoc
   where
    r     = mkNixDoc selectOp (wrapParens appOpNonAssoc r')
    ordoc =
      ((" or " <>) . wrapParens appOpNonAssoc) `whenJust` o
  NHasAttr r attr ->
    mkNixDoc hasAttrOp (wrapParens hasAttrOp r <> " ? " <> prettySelector attr)
  NEnvPath     p -> simpleExpr $ pretty @String $ "<" <> coerce p <> ">"
  NLiteralPath p ->
    pathExpr $
      pretty @FilePath $ coerce $
        case p of
          "./"  -> "./."
          "../" -> "../."
          ".."  -> "../."
          _txt  ->
            bool
              ("./" <> _txt)
              _txt
              (any (`isPrefixOf` coerce _txt) ["/", "~/", "./", "../"])
  NSym name -> simpleExpr $ prettyVarName name
  NLet binds body ->
    leastPrecedence $
      group $
        vsep
          [ "let"
          , indent 2 (vsep (fmap prettyBind binds))
          , "in " <> withoutParens body
          ]
  NIf cond trueBody falseBody ->
    leastPrecedence $
      group $
        nest 2 $
          sep
            [ "if " <> withoutParens cond
            , align ("then " <> withoutParens trueBody)
            , align ("else " <> withoutParens falseBody)
            ]
  NWith scope body ->
    prettyAddScope "with " scope body
  NAssert cond body ->
    prettyAddScope "assert " cond body
  NSynHole name -> simpleExpr $ pretty @Text ("^" <> coerce name)
 where
  prettyContainer h f t c =
    list
      (simpleExpr (h <> t))
      (const $ simpleExpr $ group $ nest 2 $ vsep $ one h <> (f <$> c) <> one t)
      c

  prettyAddScope h c b =
    leastPrecedence $
      vsep
        [h <> withoutParens c <> ";", align $ withoutParens b]


valueToExpr :: forall t f m . MonadDataContext f m => NValue t f m -> NExpr
valueToExpr = iterNValueByDiscardWith thk (Fix . phi)
 where
  thk = Fix . NSym $ "<expr>"

  phi :: NValue' t f m NExpr -> NExprF NExpr
  phi (NVConstant' a     ) = NConstant a
  phi (NVStr'      ns    ) = NStr $ DoubleQuoted $ one $ Plain $ ignoreContext ns
  phi (NVList'     l     ) = NList l
  phi (NVSet'      p    s) = NSet mempty
    [ NamedVar (one $ StaticKey k) v (fromMaybe nullPos $ (`M.lookup` p) k)
    | (k, v) <- toList s
    ]
  phi (NVClosure'  _    _) = NSym "<closure>"
  phi (NVPath'     p     ) = NLiteralPath p
  phi (NVBuiltin'  name _) = NSym $ coerce ((mappend @Text) "builtins.") name

prettyNValue
  :: forall t f m ann . MonadDataContext f m => NValue t f m -> Doc ann
prettyNValue = prettyNix . valueToExpr

prettyNValueProv
  :: forall t f m ann
   . ( HasCitations m (NValue t f m) t
     , HasCitations1 m (NValue t f m) f
     , MonadThunk t m (NValue t f m)
     , MonadDataContext f m
     )
  => NValue t f m
  -> Doc ann
prettyNValueProv v =
  list
    prettyNVal
    (\ ps ->
      fillSep
        [ prettyNVal
        , indent 2 $
          "(" <> fold (one "from: " <> (prettyOriginExpr . _originExpr <$> ps)) <> ")"
        ]
    )
    (citations @m @(NValue t f m) v)
 where
  prettyNVal = prettyNValue v

prettyNThunk
  :: forall t f m ann
   . ( HasCitations m (NValue t f m) t
     , HasCitations1 m (NValue t f m) f
     , MonadThunk t m (NValue t f m)
     , MonadDataContext f m
     )
  => t
  -> m (Doc ann)
prettyNThunk t =
  do
    let ps = citations @m @(NValue t f m) @t t
    v' <- prettyNValue <$> dethunk t
    pure $
      fillSep
        [ v'
        , indent 2 $
          "(" <> fold (one "thunk from: " <> (prettyOriginExpr . _originExpr <$> ps)) <> ")"
        ]

-- | This function is used only by the testing code.
printNix :: forall t f m . MonadDataContext f m => NValue t f m -> Text
printNix = iterNValueByDiscardWith thk phi
 where
  thk = thunkStubText

  phi :: NValue' t f m Text -> Text
  phi (NVConstant' a ) = atomText a
  phi (NVStr'      ns) = show $ ignoreContext ns
  phi (NVList'     l ) = "[ " <> unwords l <> " ]"
  phi (NVSet' _ s) =
    "{ " <>
      fold
        [ check k <> " = " <> v <> "; "
        | (coerce -> k, v) <- sort $ toList s
        ] <> "}"
   where
    check :: Text -> Text
    check v =
      fromMaybe
        v
        (tryRead @Int <|> tryRead @Float)
     where
      surround s = "\"" <> s <> "\""

      tryRead :: forall a . (Read a, Show a) => Maybe Text
      tryRead = fmap (surround . show) (readMaybe (toString v) :: Maybe a)
  phi NVClosure'{}        = "<<lambda>>"
  phi (NVPath' fp       ) = fromString $ coerce fp
  phi (NVBuiltin' name _) = "<<builtin " <> coerce name <> ">>"
