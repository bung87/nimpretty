#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module implements the parser of the standard Nim syntax.
# The parser strictly reflects the grammar ("doc/grammar.txt"); however
# it uses several helper routines to keep the parser small. A special
# efficient algorithm is used for the precedence levels. The parser here can
# be seen as a refinement of the grammar, as it specifies how the AST is built
# from the grammar and how comments belong to the AST.


import
  lexer, idents, strutils, ast, msgs, options, lineinfos,
  pathutils,streams,syntaxes

# when defined(nimpretty):
import layouter

type
  TParser* = object            # A TParser object represents a file that
                               # is being parsed
    currInd: int               # current indentation level
    firstTok: bool             # Has the first token been read?
    hasProgress: bool          # some while loop requires progress ensurance
    lex*: TLexer               # The lexer that is used for parsing
    tok*: TToken               # The current token
    inPragma*: int             # Pragma level
    inSemiStmtList*: int
    emptyNode: PNode
    # when defined(nimpretty):
    em*: Emitter

  SymbolMode = enum
    smNormal, smAllowNil, smAfterDot

  TPrimaryMode = enum
    pmNormal, pmTypeDesc, pmTypeDef, pmSkipSuffix

proc parseAll*(p: var TParser): PNode
proc closeParser*(p: var TParser)
proc parseTopLevelStmt*(p: var TParser): PNode

# helpers for the other parsers
proc isOperator*(tok: TToken): bool
proc getTok*(p: var TParser)
proc parMessage*(p: TParser, msg: TMsgKind, arg: string = "")
proc skipComment*(p: var TParser, node: PNode)
proc newNodeP*(kind: TNodeKind, p: TParser): PNode
proc newIntNodeP*(kind: TNodeKind, intVal: BiggestInt, p: TParser): PNode
proc newFloatNodeP*(kind: TNodeKind, floatVal: BiggestFloat, p: TParser): PNode
proc newStrNodeP*(kind: TNodeKind, strVal: string, p: TParser): PNode
proc newIdentNodeP*(ident: PIdent, p: TParser): PNode
proc expectIdentOrKeyw*(p: TParser)
proc expectIdent*(p: TParser)
proc parLineInfo*(p: TParser): TLineInfo
proc eat*(p: var TParser, tokType: TTokType)
proc skipInd*(p: var TParser)
proc optPar*(p: var TParser)
proc optInd*(p: var TParser, n: PNode)
proc indAndComment*(p: var TParser, n: PNode)
proc setBaseFlags*(n: PNode, base: TNumericalBase)
proc parseSymbol*(p: var TParser, mode = smNormal): PNode
proc parseTry(p: var TParser; isExpr: bool): PNode
proc parseCase(p: var TParser): PNode
proc parseStmtPragma(p: var TParser): PNode
proc parsePragma(p: var TParser): PNode
proc postExprBlocks(p: var TParser, x: PNode): PNode
proc parseExprStmt(p: var TParser): PNode
proc parseBlock(p: var TParser): PNode
proc primary(p: var TParser, mode: TPrimaryMode): PNode
proc simpleExprAux(p: var TParser, limit: int, mode: TPrimaryMode): PNode

# implementation

template prettySection(body) =
  when defined(nimpretty): beginSection(p.em)
  body
  when defined(nimpretty): endSection(p.em)

proc getTok(p: var TParser) =
  ## Get the next token from the parser's lexer, and store it in the parser's
  ## `tok` member.
  rawGetTok(p.lex, p.tok)
  p.hasProgress = true
  when defined(nimpretty):
    emitTok(p.em, p.lex, p.tok)
    # skip the additional tokens that nimpretty needs but the parser has no
    # interest in:
    while p.tok.tokType == tkComment:
      rawGetTok(p.lex, p.tok)
      emitTok(p.em, p.lex, p.tok)

proc openParser*(p: var TParser, fileIdx: FileIndex, inputStream: Stream,
                 cache: IdentCache;config: ConfigRef) =
  ## Open a parser, using the given arguments to set up its internal state.
  ##
  initToken(p.tok)
  openLexer(p.lex, fileIdx, inputStream, cache,config)
  when defined(nimpretty):
    openEmitter(p.em, cache, config, fileIdx)
  getTok(p)                   # read the first token
  p.firstTok = true
  p.emptyNode = newNode(nkEmpty)

proc openParser*(p: var TParser, filename: AbsoluteFile, inputStream: Stream,
                 cache: IdentCache; config: ConfigRef) =
  openParser(p, fileInfoIdx(config, filename), inputStream, cache, config)

proc closeParser(p: var TParser) =
  ## Close a parser, freeing up its resources.
  closeLexer(p.lex)
  when defined(nimpretty):
    closeEmitter(p.em)

proc parMessage(p: TParser, msg: TMsgKind, arg = "") =
  ## Produce and emit the parser message `arg` to output.
  lexMessageTok(p.lex, msg, p.tok, arg)

proc parMessage(p: TParser, msg: string, tok: TToken) =
  ## Produce and emit a parser message to output about the token `tok`
  parMessage(p, errGenerated, msg % prettyTok(tok))

proc parMessage(p: TParser, arg: string) =
  ## Produce and emit the parser message `arg` to output.
  lexMessageTok(p.lex, errGenerated, p.tok, arg)

template withInd(p, body: untyped) =
  let oldInd = p.currInd
  p.currInd = p.tok.indent
  body
  p.currInd = oldInd

template newlineWasSplitting(p: var TParser) =
  when defined(nimpretty):
    layouter.newlineWasSplitting(p.em)

template realInd(p): bool = p.tok.indent > p.currInd
template sameInd(p): bool = p.tok.indent == p.currInd
template sameOrNoInd(p): bool = p.tok.indent == p.currInd or p.tok.indent < 0

proc validInd(p: var TParser): bool {.inline.} =
  result = p.tok.indent < 0 or p.tok.indent > p.currInd

proc rawSkipComment(p: var TParser, node: PNode) =
  if p.tok.tokType == tkComment:
    if node != nil:
      when not defined(nimNoNilSeqs):
        if node.comment == nil: node.comment = ""
      when defined(nimpretty):
        if p.tok.commentOffsetB > p.tok.commentOffsetA:
          node.comment.add fileSection(p.lex.config, p.lex.fileIdx, p.tok.commentOffsetA, p.tok.commentOffsetB)
        else:
          node.comment.add p.tok.literal
      else:
        node.comment.add  p.tok.literal
    else:
      parMessage(p, errInternal, "skipComment")
    getTok(p)

proc skipComment(p: var TParser, node: PNode) =
  if p.tok.indent < 0: rawSkipComment(p, node)

proc flexComment(p: var TParser, node: PNode) =
  if p.tok.indent < 0 or realInd(p): rawSkipComment(p, node)

const
  errInvalidIndentation = "invalid indentation"
  errIdentifierExpected = "identifier expected, but got '$1'"
  errExprExpected = "expression expected, but found '$1'"
  errTokenExpected = "'$1' expected"

proc skipInd(p: var TParser) =
  if p.tok.indent >= 0:
    if not realInd(p): parMessage(p, errInvalidIndentation)

proc optPar(p: var TParser) =
  if p.tok.indent >= 0:
    if p.tok.indent < p.currInd: parMessage(p, errInvalidIndentation)

proc optInd(p: var TParser, n: PNode) =
  skipComment(p, n)
  skipInd(p)

proc getTokNoInd(p: var TParser) =
  getTok(p)
  if p.tok.indent >= 0: parMessage(p, errInvalidIndentation)

proc expectIdentOrKeyw(p: TParser) =
  if p.tok.tokType != tkSymbol and not isKeyword(p.tok.tokType):
    lexMessage(p.lex, errGenerated, errIdentifierExpected % prettyTok(p.tok))

proc expectIdent(p: TParser) =
  if p.tok.tokType != tkSymbol:
    lexMessage(p.lex, errGenerated, errIdentifierExpected % prettyTok(p.tok))

proc eat(p: var TParser, tokType: TTokType) =
  ## Move the parser to the next token if the current token is of type
  ## `tokType`, otherwise error.
  if p.tok.tokType == tokType:
    getTok(p)
  else:
    lexMessage(p.lex, errGenerated,
      "expected: '" & TokTypeToStr[tokType] & "', but got: '" & prettyTok(p.tok) & "'")

proc parLineInfo(p: TParser): TLineInfo =
  ## Retrieve the line information associated with the parser's current state.
  result = getLineInfo(p.lex, p.tok)

proc indAndComment(p: var TParser, n: PNode) =
  if p.tok.indent > p.currInd:
    if p.tok.tokType == tkComment: rawSkipComment(p, n)
    else: parMessage(p, errInvalidIndentation)
  else:
    skipComment(p, n)

proc newNodeP(kind: TNodeKind, p: TParser): PNode =
  result = newNodeI(kind, parLineInfo(p))

proc newIntNodeP(kind: TNodeKind, intVal: BiggestInt, p: TParser): PNode =
  result = newNodeP(kind, p)
  result.intVal = intVal

proc newFloatNodeP(kind: TNodeKind, floatVal: BiggestFloat,
                   p: TParser): PNode =
  result = newNodeP(kind, p)
  result.floatVal = floatVal

proc newStrNodeP(kind: TNodeKind, strVal: string, p: TParser): PNode =
  result = newNodeP(kind, p)
  result.strVal = strVal

proc newIdentNodeP(ident: PIdent, p: TParser): PNode =
  result = newNodeP(nkIdent, p)
  result.ident = ident

proc parseExpr(p: var TParser): PNode
proc parseStmt(p: var TParser): PNode
proc parseTypeDesc(p: var TParser): PNode
proc parseParamList(p: var TParser, retColon = true): PNode

proc isSigilLike(tok: TToken): bool {.inline.} =
  result = tok.tokType == tkOpr and tok.ident.s[0] == '@'

proc isRightAssociative(tok: TToken): bool {.inline.} =
  ## Determines whether the token is right assocative.
  result = tok.tokType == tkOpr and tok.ident.s[0] == '^'
  # or (tok.ident.s.len > 1 and tok.ident.s[^1] == '>')

proc isOperator(tok: TToken): bool =
  ## Determines if the given token is an operator type token.
  tok.tokType in {tkOpr, tkDiv, tkMod, tkShl, tkShr, tkIn, tkNotin, tkIs,
                  tkIsnot, tkNot, tkOf, tkAs, tkFrom, tkDotDot, tkAnd,
                  tkOr, tkXor}

proc isUnary(p: TParser): bool =
  ## Check if the current parser token is a unary operator
  if p.tok.tokType in {tkOpr, tkDotDot} and
     p.tok.strongSpaceB == 0 and
     p.tok.strongSpaceA > 0:
      result = true

proc checkBinary(p: TParser) {.inline.} =
  ## Check if the current parser token is a binary operator.
  # we don't check '..' here as that's too annoying
  if p.tok.tokType == tkOpr:
    if p.tok.strongSpaceB > 0 and p.tok.strongSpaceA == 0:
      parMessage(p, warnInconsistentSpacing, prettyTok(p.tok))

#| module = stmt ^* (';' / IND{=})
#|
#| comma = ',' COMMENT?
#| semicolon = ';' COMMENT?
#| colon = ':' COMMENT?
#| colcom = ':' COMMENT?
#|
#| operator =  OP0 | OP1 | OP2 | OP3 | OP4 | OP5 | OP6 | OP7 | OP8 | OP9
#|          | 'or' | 'xor' | 'and'
#|          | 'is' | 'isnot' | 'in' | 'notin' | 'of' | 'as' | 'from'
#|          | 'div' | 'mod' | 'shl' | 'shr' | 'not' | 'static' | '..'
#|
#| prefixOperator = operator
#|
#| optInd = COMMENT? IND?
#| optPar = (IND{>} | IND{=})?
#|
#| simpleExpr = arrowExpr (OP0 optInd arrowExpr)* pragma?
#| arrowExpr = assignExpr (OP1 optInd assignExpr)*
#| assignExpr = orExpr (OP2 optInd orExpr)*
#| orExpr = andExpr (OP3 optInd andExpr)*
#| andExpr = cmpExpr (OP4 optInd cmpExpr)*
#| cmpExpr = sliceExpr (OP5 optInd sliceExpr)*
#| sliceExpr = ampExpr (OP6 optInd ampExpr)*
#| ampExpr = plusExpr (OP7 optInd plusExpr)*
#| plusExpr = mulExpr (OP8 optInd mulExpr)*
#| mulExpr = dollarExpr (OP9 optInd dollarExpr)*
#| dollarExpr = primary (OP10 optInd primary)*

proc colcom(p: var TParser, n: PNode) =
  eat(p, tkColon)
  skipComment(p, n)

const tkBuiltInMagics = {tkType, tkStatic, tkAddr}

proc parseSymbol(p: var TParser, mode = smNormal): PNode =
  #| symbol = '`' (KEYW|IDENT|literal|(operator|'('|')'|'['|']'|'{'|'}'|'=')+)+ '`'
  #|        | IDENT | KEYW
  case p.tok.tokType
  of tkSymbol:
    result = newIdentNodeP(p.tok.ident, p)
    getTok(p)
  of tokKeywordLow..tokKeywordHigh:
    if p.tok.tokType in tkBuiltInMagics or mode == smAfterDot:
      # for backwards compatibility these 2 are always valid:
      result = newIdentNodeP(p.tok.ident, p)
      getTok(p)
    elif p.tok.tokType == tkNil and mode == smAllowNil:
      result = newNodeP(nkNilLit, p)
      getTok(p)
    else:
      parMessage(p, errIdentifierExpected, p.tok)
      result = p.emptyNode
  of tkAccent:
    result = newNodeP(nkAccQuoted, p)
    getTok(p)
    # progress guaranteed
    while true:
      case p.tok.tokType
      of tkAccent:
        if result.len == 0:
          parMessage(p, errIdentifierExpected, p.tok)
        break
      of tkOpr, tkDot, tkDotDot, tkEquals, tkParLe..tkParDotRi:
        let lineinfo = parLineInfo(p)
        var accm = ""
        while p.tok.tokType in {tkOpr, tkDot, tkDotDot, tkEquals,
                                tkParLe..tkParDotRi}:
          accm.add($p.tok)
          getTok(p)
        let node = newNodeI(nkIdent, lineinfo)
        node.ident = p.lex.cache.getIdent(accm)
        result.add(node)
      of tokKeywordLow..tokKeywordHigh, tkSymbol, tkIntLit..tkCharLit:
        result.add(newIdentNodeP(p.lex.cache.getIdent($p.tok), p))
        getTok(p)
      else:
        parMessage(p, errIdentifierExpected, p.tok)
        break
    eat(p, tkAccent)
  else:
    parMessage(p, errIdentifierExpected, p.tok)
    # BUGFIX: We must consume a token here to prevent endless loops!
    # But: this really sucks for idetools and keywords, so we don't do it
    # if it is a keyword:
    #if not isKeyword(p.tok.tokType): getTok(p)
    result = p.emptyNode

proc colonOrEquals(p: var TParser, a: PNode): PNode =
  if p.tok.tokType == tkColon:
    result = newNodeP(nkExprColonExpr, p)
    getTok(p)
    newlineWasSplitting(p)
    #optInd(p, result)
    result.add(a)
    result.add(parseExpr(p))
  elif p.tok.tokType == tkEquals:
    result = newNodeP(nkExprEqExpr, p)
    getTok(p)
    #optInd(p, result)
    result.add(a)
    result.add(parseExpr(p))
  else:
    result = a

proc exprColonEqExpr(p: var TParser): PNode =
  #| exprColonEqExpr = expr (':'|'=' expr)?
  var a = parseExpr(p)
  if p.tok.tokType == tkDo:
    result = postExprBlocks(p, a)
  else:
    result = colonOrEquals(p, a)

proc exprList(p: var TParser, endTok: TTokType, result: PNode) =
  #| exprList = expr ^+ comma
  when defined(nimpretty):
    inc p.em.doIndentMore
  getTok(p)
  optInd(p, result)
  # progress guaranteed
  while (p.tok.tokType != endTok) and (p.tok.tokType != tkEof):
    var a = parseExpr(p)
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  when defined(nimpretty):
    dec p.em.doIndentMore

proc exprColonEqExprListAux(p: var TParser, endTok: TTokType, result: PNode) =
  assert(endTok in {tkCurlyRi, tkCurlyDotRi, tkBracketRi, tkParRi})
  getTok(p)
  flexComment(p, result)
  optPar(p)
  # progress guaranteed
  while p.tok.tokType != endTok and p.tok.tokType != tkEof:
    var a = exprColonEqExpr(p)
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    # (1,) produces a tuple expression
    if endTok == tkParRi and p.tok.tokType == tkParRi and result.kind == nkPar:
      result.transitionSonsKind(nkTupleConstr)
    skipComment(p, a)
  optPar(p)
  eat(p, endTok)

proc exprColonEqExprList(p: var TParser, kind: TNodeKind,
                         endTok: TTokType): PNode =
  #| exprColonEqExprList = exprColonEqExpr (comma exprColonEqExpr)* (comma)?
  result = newNodeP(kind, p)
  exprColonEqExprListAux(p, endTok, result)

proc dotExpr(p: var TParser, a: PNode): PNode =
  #| dotExpr = expr '.' optInd (symbol | '[:' exprList ']')
  #| explicitGenericInstantiation = '[:' exprList ']' ( '(' exprColonEqExpr ')' )?
  var info = p.parLineInfo
  getTok(p)
  result = newNodeI(nkDotExpr, info)
  optInd(p, result)
  result.add(a)
  result.add(parseSymbol(p, smAfterDot))
  if p.tok.tokType == tkBracketLeColon and p.tok.strongSpaceA <= 0:
    var x = newNodeI(nkBracketExpr, p.parLineInfo)
    # rewrite 'x.y[:z]()' to 'y[z](x)'
    x.add result[1]
    exprList(p, tkBracketRi, x)
    eat(p, tkBracketRi)
    var y = newNodeI(nkCall, p.parLineInfo)
    y.add x
    y.add result[0]
    if p.tok.tokType == tkParLe and p.tok.strongSpaceA <= 0:
      exprColonEqExprListAux(p, tkParRi, y)
    result = y

proc qualifiedIdent(p: var TParser): PNode =
  #| qualifiedIdent = symbol ('.' optInd symbol)?
  result = parseSymbol(p)
  if p.tok.tokType == tkDot: result = dotExpr(p, result)

proc setOrTableConstr(p: var TParser): PNode =
  #| setOrTableConstr = '{' ((exprColonEqExpr comma)* | ':' ) '}'
  result = newNodeP(nkCurly, p)
  getTok(p) # skip '{'
  optInd(p, result)
  if p.tok.tokType == tkColon:
    getTok(p) # skip ':'
    result.transitionSonsKind(nkTableConstr)
  else:
    # progress guaranteed
    while p.tok.tokType notin {tkCurlyRi, tkEof}:
      var a = exprColonEqExpr(p)
      if a.kind == nkExprColonExpr: result.transitionSonsKind(nkTableConstr)
      result.add(a)
      if p.tok.tokType != tkComma: break
      getTok(p)
      skipComment(p, a)
  optPar(p)
  eat(p, tkCurlyRi) # skip '}'

proc parseCast(p: var TParser): PNode =
  #| castExpr = 'cast' '[' optInd typeDesc optPar ']' '(' optInd expr optPar ')'
  result = newNodeP(nkCast, p)
  getTok(p)
  eat(p, tkBracketLe)
  optInd(p, result)
  result.add(parseTypeDesc(p))
  optPar(p)
  eat(p, tkBracketRi)
  eat(p, tkParLe)
  optInd(p, result)
  result.add(parseExpr(p))
  optPar(p)
  eat(p, tkParRi)

proc setBaseFlags(n: PNode, base: TNumericalBase) =
  case base
  of base10: discard
  of base2: incl(n.flags, nfBase2)
  of base8: incl(n.flags, nfBase8)
  of base16: incl(n.flags, nfBase16)

proc parseGStrLit(p: var TParser, a: PNode): PNode =
  case p.tok.tokType
  of tkGStrLit:
    result = newNodeP(nkCallStrLit, p)
    result.add(a)
    result.add(newStrNodeP(nkRStrLit, p.tok.literal, p))
    getTok(p)
  of tkGTripleStrLit:
    result = newNodeP(nkCallStrLit, p)
    result.add(a)
    result.add(newStrNodeP(nkTripleStrLit, p.tok.literal, p))
    getTok(p)
  else:
    result = a

proc complexOrSimpleStmt(p: var TParser): PNode
proc simpleExpr(p: var TParser, mode = pmNormal): PNode

proc semiStmtList(p: var TParser, result: PNode) =
  inc p.inSemiStmtList
  result.add(complexOrSimpleStmt(p))
  # progress guaranteed
  while p.tok.tokType == tkSemiColon:
    getTok(p)
    optInd(p, result)
    result.add(complexOrSimpleStmt(p))
  dec p.inSemiStmtList
  result.transitionSonsKind(nkStmtListExpr)

proc parsePar(p: var TParser): PNode =
  #| parKeyw = 'discard' | 'include' | 'if' | 'while' | 'case' | 'try'
  #|         | 'finally' | 'except' | 'for' | 'block' | 'const' | 'let'
  #|         | 'when' | 'var' | 'mixin'
  #| par = '(' optInd
  #|           ( &parKeyw complexOrSimpleStmt ^+ ';'
  #|           | ';' complexOrSimpleStmt ^+ ';'
  #|           | pragmaStmt
  #|           | simpleExpr ( ('=' expr (';' complexOrSimpleStmt ^+ ';' )? )
  #|                        | (':' expr (',' exprColonEqExpr     ^+ ',' )? ) ) )
  #|           optPar ')'
  #
  # unfortunately it's ambiguous: (expr: expr) vs (exprStmt); however a
  # leading ';' could be used to enforce a 'stmt' context ...
  result = newNodeP(nkPar, p)
  getTok(p)
  optInd(p, result)
  flexComment(p, result)
  if p.tok.tokType in {tkDiscard, tkInclude, tkIf, tkWhile, tkCase,
                       tkTry, tkDefer, tkFinally, tkExcept, tkBlock,
                       tkConst, tkLet, tkWhen, tkVar, tkFor,
                       tkMixin}:
    # XXX 'bind' used to be an expression, so we exclude it here;
    # tests/reject/tbind2 fails otherwise.
    semiStmtList(p, result)
  elif p.tok.tokType == tkSemiColon:
    # '(;' enforces 'stmt' context:
    getTok(p)
    optInd(p, result)
    semiStmtList(p, result)
  elif p.tok.tokType == tkCurlyDotLe:
    result.add(parseStmtPragma(p))
  elif p.tok.tokType != tkParRi:
    var a = simpleExpr(p)
    if p.tok.tokType == tkDo:
      result = postExprBlocks(p, a)
    elif p.tok.tokType == tkEquals:
      # special case: allow assignments
      let asgn = newNodeP(nkAsgn, p)
      getTok(p)
      optInd(p, result)
      let b = parseExpr(p)
      asgn.add a
      asgn.add b
      result.add(asgn)
      if p.tok.tokType == tkSemiColon:
        semiStmtList(p, result)
    elif p.tok.tokType == tkSemiColon:
      # stmt context:
      result.add(a)
      semiStmtList(p, result)
    else:
      a = colonOrEquals(p, a)
      result.add(a)
      if p.tok.tokType == tkComma:
        getTok(p)
        skipComment(p, a)
        # (1,) produces a tuple expression:
        if p.tok.tokType == tkParRi:
          result.transitionSonsKind(nkTupleConstr)
        # progress guaranteed
        while p.tok.tokType != tkParRi and p.tok.tokType != tkEof:
          var a = exprColonEqExpr(p)
          result.add(a)
          if p.tok.tokType != tkComma: break
          getTok(p)
          skipComment(p, a)
  optPar(p)
  eat(p, tkParRi)

proc identOrLiteral(p: var TParser, mode: TPrimaryMode): PNode =
  #| literal = | INT_LIT | INT8_LIT | INT16_LIT | INT32_LIT | INT64_LIT
  #|           | UINT_LIT | UINT8_LIT | UINT16_LIT | UINT32_LIT | UINT64_LIT
  #|           | FLOAT_LIT | FLOAT32_LIT | FLOAT64_LIT
  #|           | STR_LIT | RSTR_LIT | TRIPLESTR_LIT
  #|           | CHAR_LIT
  #|           | NIL
  #| generalizedLit = GENERALIZED_STR_LIT | GENERALIZED_TRIPLESTR_LIT
  #| identOrLiteral = generalizedLit | symbol | literal
  #|                | par | arrayConstr | setOrTableConstr
  #|                | castExpr
  #| tupleConstr = '(' optInd (exprColonEqExpr comma?)* optPar ')'
  #| arrayConstr = '[' optInd (exprColonEqExpr comma?)* optPar ']'
  case p.tok.tokType
  of tkSymbol, tkBuiltInMagics, tkOut:
    result = newIdentNodeP(p.tok.ident, p)
    getTok(p)
    result = parseGStrLit(p, result)
  of tkAccent:
    result = parseSymbol(p)       # literals
  of tkIntLit:
    result = newIntNodeP(nkIntLit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkInt8Lit:
    result = newIntNodeP(nkInt8Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkInt16Lit:
    result = newIntNodeP(nkInt16Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkInt32Lit:
    result = newIntNodeP(nkInt32Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkInt64Lit:
    result = newIntNodeP(nkInt64Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkUIntLit:
    result = newIntNodeP(nkUIntLit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkUInt8Lit:
    result = newIntNodeP(nkUInt8Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkUInt16Lit:
    result = newIntNodeP(nkUInt16Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkUInt32Lit:
    result = newIntNodeP(nkUInt32Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkUInt64Lit:
    result = newIntNodeP(nkUInt64Lit, p.tok.iNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkFloatLit:
    result = newFloatNodeP(nkFloatLit, p.tok.fNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkFloat32Lit:
    result = newFloatNodeP(nkFloat32Lit, p.tok.fNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkFloat64Lit:
    result = newFloatNodeP(nkFloat64Lit, p.tok.fNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkFloat128Lit:
    result = newFloatNodeP(nkFloat128Lit, p.tok.fNumber, p)
    setBaseFlags(result, p.tok.base)
    getTok(p)
  of tkStrLit:
    result = newStrNodeP(nkStrLit, p.tok.literal, p)
    getTok(p)
  of tkRStrLit:
    result = newStrNodeP(nkRStrLit, p.tok.literal, p)
    getTok(p)
  of tkTripleStrLit:
    result = newStrNodeP(nkTripleStrLit, p.tok.literal, p)
    getTok(p)
  of tkCharLit:
    result = newIntNodeP(nkCharLit, ord(p.tok.literal[0]), p)
    getTok(p)
  of tkNil:
    result = newNodeP(nkNilLit, p)
    getTok(p)
  of tkParLe:
    # () constructor
    if mode in {pmTypeDesc, pmTypeDef}:
      result = exprColonEqExprList(p, nkPar, tkParRi)
    else:
      result = parsePar(p)
  of tkCurlyLe:
    # {} constructor
    result = setOrTableConstr(p)
  of tkBracketLe:
    # [] constructor
    result = exprColonEqExprList(p, nkBracket, tkBracketRi)
  of tkCast:
    result = parseCast(p)
  else:
    parMessage(p, errExprExpected, p.tok)
    getTok(p)  # we must consume a token here to prevent endless loops!
    result = p.emptyNode

proc namedParams(p: var TParser, callee: PNode,
                 kind: TNodeKind, endTok: TTokType): PNode =
  let a = callee
  result = newNodeP(kind, p)
  result.add(a)
  # progress guaranteed
  exprColonEqExprListAux(p, endTok, result)

proc commandParam(p: var TParser, isFirstParam: var bool; mode: TPrimaryMode): PNode =
  if mode == pmTypeDesc:
    result = simpleExpr(p, mode)
  else:
    result = parseExpr(p)
  if p.tok.tokType == tkDo:
    result = postExprBlocks(p, result)
  elif p.tok.tokType == tkEquals and not isFirstParam:
    let lhs = result
    result = newNodeP(nkExprEqExpr, p)
    getTok(p)
    result.add(lhs)
    result.add(parseExpr(p))
  isFirstParam = false

const
  tkTypeClasses = {tkRef, tkPtr, tkVar, tkStatic, tkType,
                   tkEnum, tkTuple, tkObject, tkProc}

proc commandExpr(p: var TParser; r: PNode; mode: TPrimaryMode): PNode =
  result = newNodeP(nkCommand, p)
  result.add(r)
  var isFirstParam = true
  # progress NOT guaranteed
  p.hasProgress = false
  result.add commandParam(p, isFirstParam, mode)

proc primarySuffix(p: var TParser, r: PNode,
                   baseIndent: int, mode: TPrimaryMode): PNode =
  #| primarySuffix = '(' (exprColonEqExpr comma?)* ')'
  #|       | '.' optInd symbol generalizedLit?
  #|       | '[' optInd exprColonEqExprList optPar ']'
  #|       | '{' optInd exprColonEqExprList optPar '}'
  #|       | &( '`'|IDENT|literal|'cast'|'addr'|'type') expr # command syntax
  result = r

  # progress guaranteed
  while p.tok.indent < 0 or
       (p.tok.tokType == tkDot and p.tok.indent >= baseIndent):
    case p.tok.tokType
    of tkParLe:
      # progress guaranteed
      if p.tok.strongSpaceA > 0:
        # inside type sections, expressions such as `ref (int, bar)`
        # are parsed as a nkCommand with a single tuple argument (nkPar)
        if mode == pmTypeDef:
          result = newNodeP(nkCommand, p)
          result.add r
          result.add primary(p, pmNormal)
        else:
          result = commandExpr(p, result, mode)
        break
      result = namedParams(p, result, nkCall, tkParRi)
      if result.len > 1 and result[1].kind == nkExprColonExpr:
        result.transitionSonsKind(nkObjConstr)
    of tkDot:
      # progress guaranteed
      result = dotExpr(p, result)
      result = parseGStrLit(p, result)
    of tkBracketLe:
      # progress guaranteed
      if p.tok.strongSpaceA > 0:
        result = commandExpr(p, result, mode)
        break
      result = namedParams(p, result, nkBracketExpr, tkBracketRi)
    of tkCurlyLe:
      # progress guaranteed
      if p.tok.strongSpaceA > 0:
        result = commandExpr(p, result, mode)
        break
      result = namedParams(p, result, nkCurlyExpr, tkCurlyRi)
    of tkSymbol, tkAccent, tkIntLit..tkCharLit, tkNil, tkCast,
       tkOpr, tkDotDot, tkTypeClasses - {tkRef, tkPtr}:
      # XXX: In type sections we allow the free application of the
      # command syntax, with the exception of expressions such as
      # `foo ref` or `foo ptr`. Unfortunately, these two are also
      # used as infix operators for the memory regions feature and
      # the current parsing rules don't play well here.
      if p.inPragma == 0 and (isUnary(p) or p.tok.tokType notin {tkOpr, tkDotDot}):
        # actually parsing {.push hints:off.} as {.push(hints:off).} is a sweet
        # solution, but pragmas.nim can't handle that
        result = commandExpr(p, result, mode)
      break
    else:
      break

proc parseOperators(p: var TParser, headNode: PNode,
                    limit: int, mode: TPrimaryMode): PNode =
  result = headNode
  # expand while operators have priorities higher than 'limit'
  var opPrec = getPrecedence(p.tok, false)
  let modeB = if mode == pmTypeDef: pmTypeDesc else: mode
  # the operator itself must not start on a new line:
  # progress guaranteed
  while opPrec >= limit and p.tok.indent < 0 and not isUnary(p):
    checkBinary(p)
    var leftAssoc = 1-ord(isRightAssociative(p.tok))
    var a = newNodeP(nkInfix, p)
    var opNode = newIdentNodeP(p.tok.ident, p) # skip operator:
    getTok(p)
    flexComment(p, a)
    optPar(p)
    # read sub-expression with higher priority:
    var b = simpleExprAux(p, opPrec + leftAssoc, modeB)
    a.add(opNode)
    a.add(result)
    a.add(b)
    result = a
    opPrec = getPrecedence(p.tok, false)

proc simpleExprAux(p: var TParser, limit: int, mode: TPrimaryMode): PNode =
  result = primary(p, mode)
  if p.tok.tokType == tkCurlyDotLe and (p.tok.indent < 0 or realInd(p)) and
     mode == pmNormal:
    var pragmaExp = newNodeP(nkPragmaExpr, p)
    pragmaExp.add result
    pragmaExp.add p.parsePragma
    result = pragmaExp
  result = parseOperators(p, result, limit, mode)

proc simpleExpr(p: var TParser, mode = pmNormal): PNode =
  when defined(nimpretty):
    inc p.em.doIndentMore
  result = simpleExprAux(p, -1, mode)
  when defined(nimpretty):
    dec p.em.doIndentMore

proc parseIfExpr(p: var TParser, kind: TNodeKind): PNode =
  #| condExpr = expr colcom expr optInd
  #|         ('elif' expr colcom expr optInd)*
  #|          'else' colcom expr
  #| ifExpr = 'if' condExpr
  #| whenExpr = 'when' condExpr
  when true:
    result = newNodeP(kind, p)
    while true:
      getTok(p)                 # skip `if`, `when`, `elif`
      var branch = newNodeP(nkElifExpr, p)
      optInd(p, branch)
      branch.add(parseExpr(p))
      colcom(p, branch)
      branch.add(parseStmt(p))
      skipComment(p, branch)
      result.add(branch)
      if p.tok.tokType != tkElif: break # or not sameOrNoInd(p): break
    if p.tok.tokType == tkElse: # and sameOrNoInd(p):
      var branch = newNodeP(nkElseExpr, p)
      eat(p, tkElse)
      colcom(p, branch)
      branch.add(parseStmt(p))
      result.add(branch)
  else:
    var
      b: PNode
      wasIndented = false
    result = newNodeP(kind, p)

    getTok(p)
    let branch = newNodeP(nkElifExpr, p)
    branch.add(parseExpr(p))
    colcom(p, branch)
    let oldInd = p.currInd
    if realInd(p):
      p.currInd = p.tok.indent
      wasIndented = true
    branch.add(parseExpr(p))
    result.add branch
    while sameInd(p) or not wasIndented:
      case p.tok.tokType
      of tkElif:
        b = newNodeP(nkElifExpr, p)
        getTok(p)
        optInd(p, b)
        b.add(parseExpr(p))
      of tkElse:
        b = newNodeP(nkElseExpr, p)
        getTok(p)
      else: break
      colcom(p, b)
      b.add(parseStmt(p))
      result.add(b)
      if b.kind == nkElseExpr: break
    if wasIndented:
      p.currInd = oldInd

proc parsePragma(p: var TParser): PNode =
  #| pragma = '{.' optInd (exprColonEqExpr comma?)* optPar ('.}' | '}')
  result = newNodeP(nkPragma, p)
  inc p.inPragma
  when defined(nimpretty):
    inc p.em.doIndentMore
    inc p.em.keepIndents
  getTok(p)
  optInd(p, result)
  while p.tok.tokType notin {tkCurlyDotRi, tkCurlyRi, tkEof}:
    p.hasProgress = false
    var a = exprColonEqExpr(p)
    if not p.hasProgress: break
    result.add(a)
    if p.tok.tokType == tkComma:
      getTok(p)
      skipComment(p, a)
  optPar(p)
  if p.tok.tokType in {tkCurlyDotRi, tkCurlyRi}:
    when defined(nimpretty):
      if p.tok.tokType == tkCurlyRi: curlyRiWasPragma(p.em)
    getTok(p)
  else:
    parMessage(p, "expected '.}'")
  dec p.inPragma
  when defined(nimpretty):
    dec p.em.doIndentMore
    dec p.em.keepIndents

proc identVis(p: var TParser; allowDot=false): PNode =
  #| identVis = symbol OPR?  # postfix position
  #| identVisDot = symbol '.' optInd symbol OPR?
  var a = parseSymbol(p)
  if p.tok.tokType == tkOpr:
    when defined(nimpretty):
      starWasExportMarker(p.em)
    result = newNodeP(nkPostfix, p)
    result.add(newIdentNodeP(p.tok.ident, p))
    result.add(a)
    getTok(p)
  elif p.tok.tokType == tkDot and allowDot:
    result = dotExpr(p, a)
  else:
    result = a

proc identWithPragma(p: var TParser; allowDot=false): PNode =
  #| identWithPragma = identVis pragma?
  #| identWithPragmaDot = identVisDot pragma?
  var a = identVis(p, allowDot)
  if p.tok.tokType == tkCurlyDotLe:
    result = newNodeP(nkPragmaExpr, p)
    result.add(a)
    result.add(parsePragma(p))
  else:
    result = a

type
  TDeclaredIdentFlag = enum
    withPragma,               # identifier may have pragma
    withBothOptional          # both ':' and '=' parts are optional
    withDot                   # allow 'var ident.ident = value'
  TDeclaredIdentFlags = set[TDeclaredIdentFlag]

proc parseIdentColonEquals(p: var TParser, flags: TDeclaredIdentFlags): PNode =
  #| declColonEquals = identWithPragma (comma identWithPragma)* comma?
  #|                   (':' optInd typeDesc)? ('=' optInd expr)?
  #| identColonEquals = IDENT (comma IDENT)* comma?
  #|      (':' optInd typeDesc)? ('=' optInd expr)?)
  var a: PNode
  result = newNodeP(nkIdentDefs, p)
  # progress guaranteed
  while true:
    case p.tok.tokType
    of tkSymbol, tkAccent:
      if withPragma in flags: a = identWithPragma(p, allowDot=withDot in flags)
      else: a = parseSymbol(p)
      if a.kind == nkEmpty: return
    else: break
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  if p.tok.tokType == tkColon:
    getTok(p)
    optInd(p, result)
    result.add(parseTypeDesc(p))
  else:
    result.add(newNodeP(nkEmpty, p))
    if p.tok.tokType != tkEquals and withBothOptional notin flags:
      parMessage(p, "':' or '=' expected, but got '$1'", p.tok)
  if p.tok.tokType == tkEquals:
    getTok(p)
    optInd(p, result)
    result.add(parseExpr(p))
  else:
    result.add(newNodeP(nkEmpty, p))

proc parseTuple(p: var TParser, indentAllowed = false): PNode =
  #| inlTupleDecl = 'tuple'
  #|     '[' optInd  (identColonEquals (comma/semicolon)?)*  optPar ']'
  #| extTupleDecl = 'tuple'
  #|     COMMENT? (IND{>} identColonEquals (IND{=} identColonEquals)*)?
  #| tupleClass = 'tuple'
  result = newNodeP(nkTupleTy, p)
  getTok(p)
  if p.tok.tokType == tkBracketLe:
    getTok(p)
    optInd(p, result)
    # progress guaranteed
    while p.tok.tokType in {tkSymbol, tkAccent}:
      var a = parseIdentColonEquals(p, {})
      result.add(a)
      if p.tok.tokType notin {tkComma, tkSemiColon}: break
      when defined(nimpretty):
        commaWasSemicolon(p.em)
      getTok(p)
      skipComment(p, a)
    optPar(p)
    eat(p, tkBracketRi)
  elif indentAllowed:
    skipComment(p, result)
    if realInd(p):
      withInd(p):
        rawSkipComment(p, result)
        # progress guaranteed
        while true:
          case p.tok.tokType
          of tkSymbol, tkAccent:
            var a = parseIdentColonEquals(p, {})
            if p.tok.indent < 0 or p.tok.indent >= p.currInd:
              rawSkipComment(p, a)
            result.add(a)
          of tkEof: break
          else:
            parMessage(p, errIdentifierExpected, p.tok)
            break
          if not sameInd(p): break
  elif p.tok.tokType == tkParLe:
    parMessage(p, errGenerated, "the syntax for tuple types is 'tuple[...]', not 'tuple(...)'")
  else:
    result = newNodeP(nkTupleClassTy, p)

proc parseParamList(p: var TParser, retColon = true): PNode =
  #| paramList = '(' declColonEquals ^* (comma/semicolon) ')'
  #| paramListArrow = paramList? ('->' optInd typeDesc)?
  #| paramListColon = paramList? (':' optInd typeDesc)?
  var a: PNode
  result = newNodeP(nkFormalParams, p)
  result.add(p.emptyNode) # return type
  when defined(nimpretty):
    inc p.em.doIndentMore
    inc p.em.keepIndents
  let hasParLe = p.tok.tokType == tkParLe and p.tok.indent < 0
  if hasParLe:
    getTok(p)
    optInd(p, result)
    # progress guaranteed
    while true:
      case p.tok.tokType
      of tkSymbol, tkAccent:
        a = parseIdentColonEquals(p, {withBothOptional, withPragma})
      of tkParRi:
        break
      of tkVar:
        parMessage(p, errGenerated, "the syntax is 'parameter: var T', not 'var parameter: T'")
        break
      else:
        parMessage(p, "expected closing ')'")
        break
      result.add(a)
      if p.tok.tokType notin {tkComma, tkSemiColon}: break
      when defined(nimpretty):
        commaWasSemicolon(p.em)
      getTok(p)
      skipComment(p, a)
    optPar(p)
    eat(p, tkParRi)
  let hasRet = if retColon: p.tok.tokType == tkColon
               else: p.tok.tokType == tkOpr and p.tok.ident.s == "->"
  if hasRet and p.tok.indent < 0:
    getTok(p)
    optInd(p, result)
    result[0] = parseTypeDesc(p)
  elif not retColon and not hasParLe:
    # Mark as "not there" in order to mark for deprecation in the semantic pass:
    result = p.emptyNode
  when defined(nimpretty):
    dec p.em.doIndentMore
    dec p.em.keepIndents

proc optPragmas(p: var TParser): PNode =
  if p.tok.tokType == tkCurlyDotLe and (p.tok.indent < 0 or realInd(p)):
    result = parsePragma(p)
  else:
    result = p.emptyNode

proc parseDoBlock(p: var TParser; info: TLineInfo): PNode =
  #| doBlock = 'do' paramListArrow pragma? colcom stmt
  let params = parseParamList(p, retColon=false)
  let pragmas = optPragmas(p)
  colcom(p, result)
  result = parseStmt(p)
  if params.kind != nkEmpty:
    result = newProcNode(nkDo, info,
      body = result, params = params, name = p.emptyNode, pattern = p.emptyNode,
      genericParams = p.emptyNode, pragmas = pragmas, exceptions = p.emptyNode)

proc parseProcExpr(p: var TParser; isExpr: bool; kind: TNodeKind): PNode =
  #| procExpr = 'proc' paramListColon pragma? ('=' COMMENT? stmt)?
  # either a proc type or a anonymous proc
  let info = parLineInfo(p)
  getTok(p)
  let hasSignature = p.tok.tokType in {tkParLe, tkColon} and p.tok.indent < 0
  let params = parseParamList(p)
  let pragmas = optPragmas(p)
  if p.tok.tokType == tkEquals and isExpr:
    getTok(p)
    skipComment(p, result)
    result = newProcNode(kind, info, body = parseStmt(p),
      params = params, name = p.emptyNode, pattern = p.emptyNode,
      genericParams = p.emptyNode, pragmas = pragmas, exceptions = p.emptyNode)
  else:
    result = newNodeI(nkProcTy, info)
    if hasSignature:
      result.add(params)
      if kind == nkFuncDef:
        parMessage(p, "func keyword is not allowed in type descriptions, use proc with {.noSideEffect.} pragma instead")
      result.add(pragmas)

proc isExprStart(p: TParser): bool =
  case p.tok.tokType
  of tkSymbol, tkAccent, tkOpr, tkNot, tkNil, tkCast, tkIf, tkFor,
     tkProc, tkFunc, tkIterator, tkBind, tkBuiltInMagics,
     tkParLe, tkBracketLe, tkCurlyLe, tkIntLit..tkCharLit, tkVar, tkRef, tkPtr,
     tkTuple, tkObject, tkWhen, tkCase, tkOut:
    result = true
  else: result = false

proc parseSymbolList(p: var TParser, result: PNode) =
  # progress guaranteed
  while true:
    var s = parseSymbol(p, smAllowNil)
    if s.kind == nkEmpty: break
    result.add(s)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, s)

proc parseTypeDescKAux(p: var TParser, kind: TNodeKind,
                       mode: TPrimaryMode): PNode =
  #| distinct = 'distinct' optInd typeDesc
  result = newNodeP(kind, p)
  getTok(p)
  if p.tok.indent != -1 and p.tok.indent <= p.currInd: return
  optInd(p, result)
  if not isOperator(p.tok) and isExprStart(p):
    result.add(primary(p, mode))
  if kind == nkDistinctTy and p.tok.tokType == tkSymbol:
    # XXX document this feature!
    var nodeKind: TNodeKind
    if p.tok.ident.s == "with":
      nodeKind = nkWith
    elif p.tok.ident.s == "without":
      nodeKind = nkWithout
    else:
      return result
    getTok(p)
    let list = newNodeP(nodeKind, p)
    result.add list
    parseSymbolList(p, list)

proc parseVarTuple(p: var TParser): PNode

proc parseFor(p: var TParser): PNode =
  #| forStmt = 'for' (identWithPragma ^+ comma) 'in' expr colcom stmt
  #| forExpr = forStmt
  getTokNoInd(p)
  result = newNodeP(nkForStmt, p)
  if p.tok.tokType == tkParLe:
    result.add(parseVarTuple(p))
  else:
    var a = identWithPragma(p)
    result.add(a)
    while p.tok.tokType == tkComma:
      getTok(p)
      optInd(p, a)
      if p.tok.tokType == tkParLe:
        result.add(parseVarTuple(p))
        break
      a = identWithPragma(p)
      result.add(a)
  eat(p, tkIn)
  result.add(parseExpr(p))
  colcom(p, result)
  result.add(parseStmt(p))

template nimprettyDontTouch(body) =
  when defined(nimpretty):
    inc p.em.keepIndents
  body
  when defined(nimpretty):
    dec p.em.keepIndents

proc parseExpr(p: var TParser): PNode =
  #| expr = (blockExpr
  #|       | ifExpr
  #|       | whenExpr
  #|       | caseStmt
  #|       | forExpr
  #|       | tryExpr)
  #|       / simpleExpr
  case p.tok.tokType
  of tkBlock:
    nimprettyDontTouch:
      result = parseBlock(p)
  of tkIf:
    nimprettyDontTouch:
      result = parseIfExpr(p, nkIfExpr)
  of tkFor:
    nimprettyDontTouch:
      result = parseFor(p)
  of tkWhen:
    nimprettyDontTouch:
      result = parseIfExpr(p, nkWhenExpr)
  of tkCase:
    # Currently we think nimpretty is good enough with case expressions,
    # so it is allowed to touch them:
    #nimprettyDontTouch:
    result = parseCase(p)
  of tkTry:
    nimprettyDontTouch:
      result = parseTry(p, isExpr=true)
  else: result = simpleExpr(p)

proc parseEnum(p: var TParser): PNode
proc parseObject(p: var TParser): PNode
proc parseTypeClass(p: var TParser): PNode

proc primary(p: var TParser, mode: TPrimaryMode): PNode =
  #| typeKeyw = 'var' | 'out' | 'ref' | 'ptr' | 'shared' | 'tuple'
  #|          | 'proc' | 'iterator' | 'distinct' | 'object' | 'enum'
  #| primary = typeKeyw optInd typeDesc
  #|         /  prefixOperator* identOrLiteral primarySuffix*
  #|         / 'bind' primary
  if isOperator(p.tok):
    let isSigil = isSigilLike(p.tok)
    result = newNodeP(nkPrefix, p)
    var a = newIdentNodeP(p.tok.ident, p)
    result.add(a)
    getTok(p)
    optInd(p, a)
    if isSigil:
      #XXX prefix operators
      let baseInd = p.lex.currLineIndent
      result.add(primary(p, pmSkipSuffix))
      result = primarySuffix(p, result, baseInd, mode)
    else:
      result.add(primary(p, pmNormal))
    return

  case p.tok.tokType:
  of tkTuple: result = parseTuple(p, mode == pmTypeDef)
  of tkProc: result = parseProcExpr(p, mode notin {pmTypeDesc, pmTypeDef}, nkLambda)
  of tkFunc: result = parseProcExpr(p, mode notin {pmTypeDesc, pmTypeDef}, nkFuncDef)
  of tkIterator:
    result = parseProcExpr(p, mode notin {pmTypeDesc, pmTypeDef}, nkLambda)
    if result.kind == nkLambda: result.transitionSonsKind(nkIteratorDef)
    else: result.transitionSonsKind(nkIteratorTy)
  of tkEnum:
    if mode == pmTypeDef:
      prettySection:
        result = parseEnum(p)
    else:
      result = newNodeP(nkEnumTy, p)
      getTok(p)
  of tkObject:
    if mode == pmTypeDef:
      prettySection:
        result = parseObject(p)
    else:
      result = newNodeP(nkObjectTy, p)
      getTok(p)
  of tkConcept:
    if mode == pmTypeDef:
      result = parseTypeClass(p)
    else:
      parMessage(p, "the 'concept' keyword is only valid in 'type' sections")
  of tkBind:
    result = newNodeP(nkBind, p)
    getTok(p)
    optInd(p, result)
    result.add(primary(p, pmNormal))
  of tkVar: result = parseTypeDescKAux(p, nkVarTy, mode)
  of tkRef: result = parseTypeDescKAux(p, nkRefTy, mode)
  of tkPtr: result = parseTypeDescKAux(p, nkPtrTy, mode)
  of tkDistinct: result = parseTypeDescKAux(p, nkDistinctTy, mode)
  else:
    let baseInd = p.lex.currLineIndent
    result = identOrLiteral(p, mode)
    if mode != pmSkipSuffix:
      result = primarySuffix(p, result, baseInd, mode)

proc binaryNot(p: var TParser; a: PNode): PNode =
  if p.tok.tokType == tkNot:
    let notOpr = newIdentNodeP(p.tok.ident, p)
    getTok(p)
    optInd(p, notOpr)
    let b = parseExpr(p)
    result = newNodeP(nkInfix, p)
    result.add notOpr
    result.add a
    result.add b
  else:
    result = a

proc parseTypeDesc(p: var TParser): PNode =
  #| typeDesc = simpleExpr ('not' expr)?
  newlineWasSplitting(p)
  result = simpleExpr(p, pmTypeDesc)
  result = binaryNot(p, result)

proc parseTypeDefAux(p: var TParser): PNode =
  #| typeDefAux = simpleExpr ('not' expr)?
  #|            | 'concept' typeClass
  result = simpleExpr(p, pmTypeDef)
  result = binaryNot(p, result)

proc makeCall(n: PNode): PNode =
  ## Creates a call if the given node isn't already a call.
  if n.kind in nkCallKinds:
    result = n
  else:
    result = newNodeI(nkCall, n.info)
    result.add n

proc postExprBlocks(p: var TParser, x: PNode): PNode =
  #| postExprBlocks = ':' stmt? ( IND{=} doBlock
  #|                            | IND{=} 'of' exprList ':' stmt
  #|                            | IND{=} 'elif' expr ':' stmt
  #|                            | IND{=} 'except' exprList ':' stmt
  #|                            | IND{=} 'else' ':' stmt )*
  result = x
  if p.tok.indent >= 0: return

  var
    openingParams = p.emptyNode
    openingPragmas = p.emptyNode

  if p.tok.tokType == tkDo:
    getTok(p)
    openingParams = parseParamList(p, retColon=false)
    openingPragmas = optPragmas(p)

  if p.tok.tokType == tkColon:
    result = makeCall(result)
    getTok(p)
    skipComment(p, result)
    if p.tok.tokType notin {tkOf, tkElif, tkElse, tkExcept}:
      var stmtList = newNodeP(nkStmtList, p)
      stmtList.add parseStmt(p)
      # to keep backwards compatibility (see tests/vm/tstringnil)
      if stmtList[0].kind == nkStmtList: stmtList = stmtList[0]

      stmtList.flags.incl nfBlockArg
      if openingParams.kind != nkEmpty:
        result.add newProcNode(nkDo, stmtList.info, body = stmtList,
                               params = openingParams,
                               name = p.emptyNode, pattern = p.emptyNode,
                               genericParams = p.emptyNode,
                               pragmas = openingPragmas,
                               exceptions = p.emptyNode)
      else:
        result.add stmtList

    while sameInd(p):
      var nextBlock: PNode
      let nextToken = p.tok.tokType
      if nextToken == tkDo:
        let info = parLineInfo(p)
        getTok(p)
        nextBlock = parseDoBlock(p, info)
      else:
        case nextToken:
        of tkOf:
          nextBlock = newNodeP(nkOfBranch, p)
          exprList(p, tkColon, nextBlock)
        of tkElif:
          nextBlock = newNodeP(nkElifBranch, p)
          getTok(p)
          optInd(p, nextBlock)
          nextBlock.add parseExpr(p)
        of tkExcept:
          nextBlock = newNodeP(nkExceptBranch, p)
          exprList(p, tkColon, nextBlock)
        of tkElse:
          nextBlock = newNodeP(nkElse, p)
          getTok(p)
        else: break
        eat(p, tkColon)
        nextBlock.add parseStmt(p)

      nextBlock.flags.incl nfBlockArg
      result.add nextBlock

      if nextBlock.kind == nkElse: break
  else:
    if openingParams.kind != nkEmpty:
      parMessage(p, "expected ':'")

proc parseExprStmt(p: var TParser): PNode =
  #| exprStmt = simpleExpr
  #|          (( '=' optInd expr colonBody? )
  #|          / ( expr ^+ comma
  #|              postExprBlocks
  #|            ))?
  var a = simpleExpr(p)
  if p.tok.tokType == tkEquals:
    result = newNodeP(nkAsgn, p)
    getTok(p)
    optInd(p, result)
    var b = parseExpr(p)
    b = postExprBlocks(p, b)
    result.add(a)
    result.add(b)
  else:
    # simpleExpr parsed 'p a' from 'p a, b'?
    var isFirstParam = false
    if p.tok.indent < 0 and p.tok.tokType == tkComma and a.kind == nkCommand:
      result = a
      while true:
        getTok(p)
        optInd(p, result)
        result.add(commandParam(p, isFirstParam, pmNormal))
        if p.tok.tokType != tkComma: break
    elif p.tok.indent < 0 and isExprStart(p):
      result = newNode(nkCommand, a.info, @[a])
      while true:
        result.add(commandParam(p, isFirstParam, pmNormal))
        if p.tok.tokType != tkComma: break
        getTok(p)
        optInd(p, result)
    else:
      result = a
    result = postExprBlocks(p, result)

proc parseModuleName(p: var TParser, kind: TNodeKind): PNode =
  result = parseExpr(p)
  when false:
    # parseExpr already handles 'as' syntax ...
    if p.tok.tokType == tkAs and kind == nkImportStmt:
      let a = result
      result = newNodeP(nkImportAs, p)
      getTok(p)
      result.add(a)
      result.add(parseExpr(p))

proc parseImport(p: var TParser, kind: TNodeKind): PNode =
  #| importStmt = 'import' optInd expr
  #|               ((comma expr)*
  #|               / 'except' optInd (expr ^+ comma))
  #| exportStmt = 'export' optInd expr
  #|               ((comma expr)*
  #|               / 'except' optInd (expr ^+ comma))
  result = newNodeP(kind, p)
  getTok(p)                   # skip `import` or `export`
  optInd(p, result)
  var a = parseModuleName(p, kind)
  result.add(a)
  if p.tok.tokType in {tkComma, tkExcept}:
    if p.tok.tokType == tkExcept:
      result.transitionSonsKind(succ(kind))
    getTok(p)
    optInd(p, result)
    while true:
      # was: while p.tok.tokType notin {tkEof, tkSad, tkDed}:
      p.hasProgress = false
      a = parseModuleName(p, kind)
      if a.kind == nkEmpty or not p.hasProgress: break
      result.add(a)
      if p.tok.tokType != tkComma: break
      getTok(p)
      optInd(p, a)
  #expectNl(p)

proc parseIncludeStmt(p: var TParser): PNode =
  #| includeStmt = 'include' optInd expr ^+ comma
  result = newNodeP(nkIncludeStmt, p)
  getTok(p)                   # skip `import` or `include`
  optInd(p, result)
  while true:
    # was: while p.tok.tokType notin {tkEof, tkSad, tkDed}:
    p.hasProgress = false
    var a = parseExpr(p)
    if a.kind == nkEmpty or not p.hasProgress: break
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  #expectNl(p)

proc parseFromStmt(p: var TParser): PNode =
  #| fromStmt = 'from' expr 'import' optInd expr (comma expr)*
  result = newNodeP(nkFromStmt, p)
  getTok(p)                   # skip `from`
  optInd(p, result)
  var a = parseModuleName(p, nkImportStmt)
  result.add(a)           #optInd(p, a);
  eat(p, tkImport)
  optInd(p, result)
  while true:
    # p.tok.tokType notin {tkEof, tkSad, tkDed}:
    p.hasProgress = false
    a = parseExpr(p)
    if a.kind == nkEmpty or not p.hasProgress: break
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  #expectNl(p)

proc parseReturnOrRaise(p: var TParser, kind: TNodeKind): PNode =
  #| returnStmt = 'return' optInd expr?
  #| raiseStmt = 'raise' optInd expr?
  #| yieldStmt = 'yield' optInd expr?
  #| discardStmt = 'discard' optInd expr?
  #| breakStmt = 'break' optInd expr?
  #| continueStmt = 'break' optInd expr?
  result = newNodeP(kind, p)
  getTok(p)
  if p.tok.tokType == tkComment:
    skipComment(p, result)
    result.add(p.emptyNode)
  elif p.tok.indent >= 0 and p.tok.indent <= p.currInd or not isExprStart(p):
    # NL terminates:
    result.add(p.emptyNode)
    # nimpretty here!
  else:
    var e = parseExpr(p)
    e = postExprBlocks(p, e)
    result.add(e)

proc parseIfOrWhen(p: var TParser, kind: TNodeKind): PNode =
  #| condStmt = expr colcom stmt COMMENT?
  #|            (IND{=} 'elif' expr colcom stmt)*
  #|            (IND{=} 'else' colcom stmt)?
  #| ifStmt = 'if' condStmt
  #| whenStmt = 'when' condStmt
  result = newNodeP(kind, p)
  while true:
    getTok(p)                 # skip `if`, `when`, `elif`
    var branch = newNodeP(nkElifBranch, p)
    optInd(p, branch)
    branch.add(parseExpr(p))
    colcom(p, branch)
    branch.add(parseStmt(p))
    skipComment(p, branch)
    result.add(branch)
    if p.tok.tokType != tkElif or not sameOrNoInd(p): break
  if p.tok.tokType == tkElse and sameOrNoInd(p):
    var branch = newNodeP(nkElse, p)
    eat(p, tkElse)
    colcom(p, branch)
    branch.add(parseStmt(p))
    result.add(branch)

proc parseWhile(p: var TParser): PNode =
  #| whileStmt = 'while' expr colcom stmt
  result = newNodeP(nkWhileStmt, p)
  getTok(p)
  optInd(p, result)
  result.add(parseExpr(p))
  colcom(p, result)
  result.add(parseStmt(p))

proc parseCase(p: var TParser): PNode =
  #| ofBranch = 'of' exprList colcom stmt
  #| ofBranches = ofBranch (IND{=} ofBranch)*
  #|                       (IND{=} 'elif' expr colcom stmt)*
  #|                       (IND{=} 'else' colcom stmt)?
  #| caseStmt = 'case' expr ':'? COMMENT?
  #|             (IND{>} ofBranches DED
  #|             | IND{=} ofBranches)
  var
    b: PNode
    inElif = false
    wasIndented = false
  result = newNodeP(nkCaseStmt, p)
  getTok(p)
  result.add(parseExpr(p))
  if p.tok.tokType == tkColon: getTok(p)
  skipComment(p, result)

  let oldInd = p.currInd
  if realInd(p):
    p.currInd = p.tok.indent
    wasIndented = true

  while sameInd(p):
    case p.tok.tokType
    of tkOf:
      if inElif: break
      b = newNodeP(nkOfBranch, p)
      exprList(p, tkColon, b)
    of tkElif:
      inElif = true
      b = newNodeP(nkElifBranch, p)
      getTok(p)
      optInd(p, b)
      b.add(parseExpr(p))
    of tkElse:
      b = newNodeP(nkElse, p)
      getTok(p)
    else: break
    colcom(p, b)
    b.add(parseStmt(p))
    result.add(b)
    if b.kind == nkElse: break

  if wasIndented:
    p.currInd = oldInd

proc parseTry(p: var TParser; isExpr: bool): PNode =
  #| tryStmt = 'try' colcom stmt &(IND{=}? 'except'|'finally')
  #|            (IND{=}? 'except' exprList colcom stmt)*
  #|            (IND{=}? 'finally' colcom stmt)?
  #| tryExpr = 'try' colcom stmt &(optInd 'except'|'finally')
  #|            (optInd 'except' exprList colcom stmt)*
  #|            (optInd 'finally' colcom stmt)?
  result = newNodeP(nkTryStmt, p)
  getTok(p)
  colcom(p, result)
  result.add(parseStmt(p))
  var b: PNode = nil
  while sameOrNoInd(p) or isExpr:
    case p.tok.tokType
    of tkExcept:
      b = newNodeP(nkExceptBranch, p)
      exprList(p, tkColon, b)
    of tkFinally:
      b = newNodeP(nkFinally, p)
      getTok(p)
    else: break
    colcom(p, b)
    b.add(parseStmt(p))
    result.add(b)
  if b == nil: parMessage(p, "expected 'except'")

proc parseExceptBlock(p: var TParser, kind: TNodeKind): PNode =
  #| exceptBlock = 'except' colcom stmt
  result = newNodeP(kind, p)
  getTok(p)
  colcom(p, result)
  result.add(parseStmt(p))

proc parseBlock(p: var TParser): PNode =
  #| blockStmt = 'block' symbol? colcom stmt
  #| blockExpr = 'block' symbol? colcom stmt
  result = newNodeP(nkBlockStmt, p)
  getTokNoInd(p)
  if p.tok.tokType == tkColon: result.add(p.emptyNode)
  else: result.add(parseSymbol(p))
  colcom(p, result)
  result.add(parseStmt(p))

proc parseStaticOrDefer(p: var TParser; k: TNodeKind): PNode =
  #| staticStmt = 'static' colcom stmt
  #| deferStmt = 'defer' colcom stmt
  result = newNodeP(k, p)
  getTok(p)
  colcom(p, result)
  result.add(parseStmt(p))

proc parseAsm(p: var TParser): PNode =
  #| asmStmt = 'asm' pragma? (STR_LIT | RSTR_LIT | TRIPLESTR_LIT)
  result = newNodeP(nkAsmStmt, p)
  getTokNoInd(p)
  if p.tok.tokType == tkCurlyDotLe: result.add(parsePragma(p))
  else: result.add(p.emptyNode)
  case p.tok.tokType
  of tkStrLit: result.add(newStrNodeP(nkStrLit, p.tok.literal, p))
  of tkRStrLit: result.add(newStrNodeP(nkRStrLit, p.tok.literal, p))
  of tkTripleStrLit: result.add(newStrNodeP(nkTripleStrLit, p.tok.literal, p))
  else:
    parMessage(p, "the 'asm' statement takes a string literal")
    result.add(p.emptyNode)
    return
  getTok(p)

proc parseGenericParam(p: var TParser): PNode =
  #| genericParam = symbol (comma symbol)* (colon expr)? ('=' optInd expr)?
  var a: PNode
  result = newNodeP(nkIdentDefs, p)
  # progress guaranteed
  while true:
    case p.tok.tokType
    of tkIn, tkOut:
      let x = p.lex.cache.getIdent(if p.tok.tokType == tkIn: "in" else: "out")
      a = newNodeP(nkPrefix, p)
      a.add newIdentNodeP(x, p)
      getTok(p)
      expectIdent(p)
      a.add(parseSymbol(p))
    of tkSymbol, tkAccent:
      a = parseSymbol(p)
      if a.kind == nkEmpty: return
    else: break
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  if p.tok.tokType == tkColon:
    getTok(p)
    optInd(p, result)
    result.add(parseExpr(p))
  else:
    result.add(p.emptyNode)
  if p.tok.tokType == tkEquals:
    getTok(p)
    optInd(p, result)
    result.add(parseExpr(p))
  else:
    result.add(p.emptyNode)

proc parseGenericParamList(p: var TParser): PNode =
  #| genericParamList = '[' optInd
  #|   genericParam ^* (comma/semicolon) optPar ']'
  result = newNodeP(nkGenericParams, p)
  getTok(p)
  optInd(p, result)
  # progress guaranteed
  while p.tok.tokType in {tkSymbol, tkAccent, tkIn, tkOut}:
    var a = parseGenericParam(p)
    result.add(a)
    if p.tok.tokType notin {tkComma, tkSemiColon}: break
    when defined(nimpretty):
      commaWasSemicolon(p.em)
    getTok(p)
    skipComment(p, a)
  optPar(p)
  eat(p, tkBracketRi)

proc parsePattern(p: var TParser): PNode =
  #| pattern = '{' stmt '}'
  eat(p, tkCurlyLe)
  result = parseStmt(p)
  eat(p, tkCurlyRi)

proc parseRoutine(p: var TParser, kind: TNodeKind): PNode =
  #| indAndComment = (IND{>} COMMENT)? | COMMENT?
  #| routine = optInd identVis pattern? genericParamList?
  #|   paramListColon pragma? ('=' COMMENT? stmt)? indAndComment
  result = newNodeP(kind, p)
  getTok(p)
  optInd(p, result)
  result.add(identVis(p))
  if p.tok.tokType == tkCurlyLe and p.validInd: result.add(p.parsePattern)
  else: result.add(p.emptyNode)
  if p.tok.tokType == tkBracketLe and p.validInd:
    result.add(p.parseGenericParamList)
  else:
    result.add(p.emptyNode)
  result.add(p.parseParamList)
  if p.tok.tokType == tkCurlyDotLe and p.validInd: result.add(p.parsePragma)
  else: result.add(p.emptyNode)
  # empty exception tracking:
  result.add(p.emptyNode)
  if p.tok.tokType == tkEquals and p.validInd:
    getTok(p)
    skipComment(p, result)
    result.add(parseStmt(p))
  else:
    result.add(p.emptyNode)
  indAndComment(p, result)

proc newCommentStmt(p: var TParser): PNode =
  #| commentStmt = COMMENT
  result = newNodeP(nkCommentStmt, p)
  result.comment = p.tok.literal
  getTok(p)

type
  TDefParser = proc (p: var TParser): PNode {.nimcall.}

proc parseSection(p: var TParser, kind: TNodeKind,
                  defparser: TDefParser): PNode =
  #| section(RULE) = COMMENT? RULE / (IND{>} (RULE / COMMENT)^+IND{=} DED)
  result = newNodeP(kind, p)
  if kind != nkTypeSection: getTok(p)
  skipComment(p, result)
  if realInd(p):
    withInd(p):
      skipComment(p, result)
      # progress guaranteed
      while sameInd(p):
        case p.tok.tokType
        of tkSymbol, tkAccent, tkParLe:
          var a = defparser(p)
          skipComment(p, a)
          result.add(a)
        of tkComment:
          var a = newCommentStmt(p)
          result.add(a)
        else:
          parMessage(p, errIdentifierExpected, p.tok)
          break
    if result.len == 0: parMessage(p, errIdentifierExpected, p.tok)
  elif p.tok.tokType in {tkSymbol, tkAccent, tkParLe} and p.tok.indent < 0:
    # tkParLe is allowed for ``var (x, y) = ...`` tuple parsing
    result.add(defparser(p))
  else:
    parMessage(p, errIdentifierExpected, p.tok)

proc parseEnum(p: var TParser): PNode =
  #| enum = 'enum' optInd (symbol pragma? optInd ('=' optInd expr COMMENT?)? comma?)+
  result = newNodeP(nkEnumTy, p)
  getTok(p)
  result.add(p.emptyNode)
  optInd(p, result)
  flexComment(p, result)
  # progress guaranteed
  while true:
    var a = parseSymbol(p)
    if a.kind == nkEmpty: return

    var symPragma = a
    var pragma: PNode
    if p.tok.tokType == tkCurlyDotLe:
      pragma = optPragmas(p)
      symPragma = newNodeP(nkPragmaExpr, p)
      symPragma.add(a)
      symPragma.add(pragma)
    # nimpretty support here
    if p.tok.indent >= 0 and p.tok.indent <= p.currInd:
      result.add(symPragma)
      break

    if p.tok.tokType == tkEquals and p.tok.indent < 0:
      getTok(p)
      optInd(p, symPragma)
      var b = symPragma
      symPragma = newNodeP(nkEnumFieldDef, p)
      symPragma.add(b)
      symPragma.add(parseExpr(p))
      if p.tok.indent < 0 or p.tok.indent >= p.currInd:
        rawSkipComment(p, symPragma)
    if p.tok.tokType == tkComma and p.tok.indent < 0:
      getTok(p)
      rawSkipComment(p, symPragma)
    else:
      if p.tok.indent < 0 or p.tok.indent >= p.currInd:
        rawSkipComment(p, symPragma)
    result.add(symPragma)
    if p.tok.indent >= 0 and p.tok.indent <= p.currInd or
        p.tok.tokType == tkEof:
      break
  if result.len <= 1:
    parMessage(p, errIdentifierExpected, p.tok)

proc parseObjectPart(p: var TParser): PNode
proc parseObjectWhen(p: var TParser): PNode =
  #| objectWhen = 'when' expr colcom objectPart COMMENT?
  #|             ('elif' expr colcom objectPart COMMENT?)*
  #|             ('else' colcom objectPart COMMENT?)?
  result = newNodeP(nkRecWhen, p)
  # progress guaranteed
  while sameInd(p):
    getTok(p)                 # skip `when`, `elif`
    var branch = newNodeP(nkElifBranch, p)
    optInd(p, branch)
    branch.add(parseExpr(p))
    colcom(p, branch)
    branch.add(parseObjectPart(p))
    flexComment(p, branch)
    result.add(branch)
    if p.tok.tokType != tkElif: break
  if p.tok.tokType == tkElse and sameInd(p):
    var branch = newNodeP(nkElse, p)
    eat(p, tkElse)
    colcom(p, branch)
    branch.add(parseObjectPart(p))
    flexComment(p, branch)
    result.add(branch)

proc parseObjectCase(p: var TParser): PNode =
  #| objectBranch = 'of' exprList colcom objectPart
  #| objectBranches = objectBranch (IND{=} objectBranch)*
  #|                       (IND{=} 'elif' expr colcom objectPart)*
  #|                       (IND{=} 'else' colcom objectPart)?
  #| objectCase = 'case' identWithPragma ':' typeDesc ':'? COMMENT?
  #|             (IND{>} objectBranches DED
  #|             | IND{=} objectBranches)
  result = newNodeP(nkRecCase, p)
  getTokNoInd(p)
  var a = newNodeP(nkIdentDefs, p)
  a.add(identWithPragma(p))
  eat(p, tkColon)
  a.add(parseTypeDesc(p))
  a.add(p.emptyNode)
  result.add(a)
  if p.tok.tokType == tkColon: getTok(p)
  flexComment(p, result)
  var wasIndented = false
  let oldInd = p.currInd
  if realInd(p):
    p.currInd = p.tok.indent
    wasIndented = true
  # progress guaranteed
  while sameInd(p):
    var b: PNode
    case p.tok.tokType
    of tkOf:
      b = newNodeP(nkOfBranch, p)
      exprList(p, tkColon, b)
    of tkElse:
      b = newNodeP(nkElse, p)
      getTok(p)
    else: break
    colcom(p, b)
    var fields = parseObjectPart(p)
    if fields.kind == nkEmpty:
      parMessage(p, errIdentifierExpected, p.tok)
      fields = newNodeP(nkNilLit, p) # don't break further semantic checking
    b.add(fields)
    result.add(b)
    if b.kind == nkElse: break
  if wasIndented:
    p.currInd = oldInd

proc parseObjectPart(p: var TParser): PNode =
  #| objectPart = IND{>} objectPart^+IND{=} DED
  #|            / objectWhen / objectCase / 'nil' / 'discard' / declColonEquals
  if realInd(p):
    result = newNodeP(nkRecList, p)
    withInd(p):
      rawSkipComment(p, result)
      while sameInd(p):
        case p.tok.tokType
        of tkCase, tkWhen, tkSymbol, tkAccent, tkNil, tkDiscard:
          result.add(parseObjectPart(p))
        else:
          parMessage(p, errIdentifierExpected, p.tok)
          break
  else:
    case p.tok.tokType
    of tkWhen:
      result = parseObjectWhen(p)
    of tkCase:
      result = parseObjectCase(p)
    of tkSymbol, tkAccent:
      result = parseIdentColonEquals(p, {withPragma})
      if p.tok.indent < 0 or p.tok.indent >= p.currInd:
        rawSkipComment(p, result)
    of tkNil, tkDiscard:
      result = newNodeP(nkNilLit, p)
      getTok(p)
    else:
      result = p.emptyNode

proc parseObject(p: var TParser): PNode =
  #| object = 'object' pragma? ('of' typeDesc)? COMMENT? objectPart
  result = newNodeP(nkObjectTy, p)
  getTok(p)
  if p.tok.tokType == tkCurlyDotLe and p.validInd:
    # Deprecated since v0.20.0
    parMessage(p, warnDeprecated, "type pragmas follow the type name; this form of writing pragmas is deprecated")
    result.add(parsePragma(p))
  else:
    result.add(p.emptyNode)
  if p.tok.tokType == tkOf and p.tok.indent < 0:
    var a = newNodeP(nkOfInherit, p)
    getTok(p)
    a.add(parseTypeDesc(p))
    result.add(a)
  else:
    result.add(p.emptyNode)
  if p.tok.tokType == tkComment:
    skipComment(p, result)
  # an initial IND{>} HAS to follow:
  if not realInd(p):
    result.add(p.emptyNode)
    return
  result.add(parseObjectPart(p))

proc parseTypeClassParam(p: var TParser): PNode =
  let modifier = case p.tok.tokType
    of tkOut, tkVar: nkVarTy
    of tkPtr: nkPtrTy
    of tkRef: nkRefTy
    of tkStatic: nkStaticTy
    of tkType: nkTypeOfExpr
    else: nkEmpty

  if modifier != nkEmpty:
    result = newNodeP(modifier, p)
    getTok(p)
    result.add(p.parseSymbol)
  else:
    result = p.parseSymbol

proc parseTypeClass(p: var TParser): PNode =
  #| typeClassParam = ('var' | 'out')? symbol
  #| typeClass = typeClassParam ^* ',' (pragma)? ('of' typeDesc ^* ',')?
  #|               &IND{>} stmt
  result = newNodeP(nkTypeClassTy, p)
  getTok(p)
  var args = newNodeP(nkArgList, p)
  result.add(args)
  args.add(p.parseTypeClassParam)
  while p.tok.tokType == tkComma:
    getTok(p)
    args.add(p.parseTypeClassParam)
  if p.tok.tokType == tkCurlyDotLe and p.validInd:
    result.add(parsePragma(p))
  else:
    result.add(p.emptyNode)
  if p.tok.tokType == tkOf and p.tok.indent < 0:
    var a = newNodeP(nkOfInherit, p)
    getTok(p)
    # progress guaranteed
    while true:
      a.add(parseTypeDesc(p))
      if p.tok.tokType != tkComma: break
      getTok(p)
    result.add(a)
  else:
    result.add(p.emptyNode)
  if p.tok.tokType == tkComment:
    skipComment(p, result)
  # an initial IND{>} HAS to follow:
  if not realInd(p):
    result.add(p.emptyNode)
  else:
    result.add(parseStmt(p))

proc parseTypeDef(p: var TParser): PNode =
  #|
  #| typeDef = identWithPragmaDot genericParamList? '=' optInd typeDefAux
  #|             indAndComment? / identVisDot genericParamList? pragma '=' optInd typeDefAux
  #|             indAndComment?
  result = newNodeP(nkTypeDef, p)
  var identifier = identVis(p, allowDot=true)
  var identPragma = identifier
  var pragma: PNode
  var genericParam: PNode
  var noPragmaYet = true

  if p.tok.tokType == tkCurlyDotLe:
    pragma = optPragmas(p)
    identPragma = newNodeP(nkPragmaExpr, p)
    identPragma.add(identifier)
    identPragma.add(pragma)
    noPragmaYet = false

  if p.tok.tokType == tkBracketLe and p.validInd:
    if not noPragmaYet:
      # Deprecated since v0.20.0
      parMessage(p, warnDeprecated, "pragma before generic parameter list is deprecated")
    genericParam = parseGenericParamList(p)
  else:
    genericParam = p.emptyNode

  if noPragmaYet:
    pragma = optPragmas(p)
    if pragma.kind != nkEmpty:
      identPragma = newNodeP(nkPragmaExpr, p)
      identPragma.add(identifier)
      identPragma.add(pragma)
  elif p.tok.tokType == tkCurlyDotLe:
    parMessage(p, errGenerated, "pragma already present")

  result.add(identPragma)
  result.add(genericParam)

  if p.tok.tokType == tkEquals:
    result.info = parLineInfo(p)
    getTok(p)
    optInd(p, result)
    result.add(parseTypeDefAux(p))
  else:
    result.add(p.emptyNode)
  indAndComment(p, result)    # special extension!

proc parseVarTuple(p: var TParser): PNode =
  #| varTuple = '(' optInd identWithPragma ^+ comma optPar ')' '=' optInd expr
  result = newNodeP(nkVarTuple, p)
  getTok(p)                   # skip '('
  optInd(p, result)
  # progress guaranteed
  while p.tok.tokType in {tkSymbol, tkAccent}:
    var a = identWithPragma(p, allowDot=true)
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    skipComment(p, a)
  result.add(p.emptyNode)         # no type desc
  optPar(p)
  eat(p, tkParRi)

proc parseVariable(p: var TParser): PNode =
  #| colonBody = colcom stmt postExprBlocks?
  #| variable = (varTuple / identColonEquals) colonBody? indAndComment
  if p.tok.tokType == tkParLe:
    result = parseVarTuple(p)
    eat(p, tkEquals)
    optInd(p, result)
    result.add(parseExpr(p))
  else: result = parseIdentColonEquals(p, {withPragma, withDot})
  result[^1] = postExprBlocks(p, result[^1])
  indAndComment(p, result)

proc parseConstant(p: var TParser): PNode =
  #| constant = (varTuple / identWithPragma) (colon typeDesc)? '=' optInd expr indAndComment
  if p.tok.tokType == tkParLe: result = parseVarTuple(p)
  else:
    result = newNodeP(nkConstDef, p)
    result.add(identWithPragma(p))
    if p.tok.tokType == tkColon:
      getTok(p)
      optInd(p, result)
      result.add(parseTypeDesc(p))
    else:
      result.add(p.emptyNode)
  eat(p, tkEquals)
  optInd(p, result)
  #add(result, parseStmtListExpr(p))
  result.add(parseExpr(p))
  result[^1] = postExprBlocks(p, result[^1])
  indAndComment(p, result)

proc parseBind(p: var TParser, k: TNodeKind): PNode =
  #| bindStmt = 'bind' optInd qualifiedIdent ^+ comma
  #| mixinStmt = 'mixin' optInd qualifiedIdent ^+ comma
  result = newNodeP(k, p)
  getTok(p)
  optInd(p, result)
  # progress guaranteed
  while true:
    var a = qualifiedIdent(p)
    result.add(a)
    if p.tok.tokType != tkComma: break
    getTok(p)
    optInd(p, a)
  #expectNl(p)

proc parseStmtPragma(p: var TParser): PNode =
  #| pragmaStmt = pragma (':' COMMENT? stmt)?
  result = parsePragma(p)
  if p.tok.tokType == tkColon and p.tok.indent < 0:
    let a = result
    result = newNodeI(nkPragmaBlock, a.info)
    getTok(p)
    skipComment(p, result)
    result.add a
    result.add parseStmt(p)

proc simpleStmt(p: var TParser): PNode =
  #| simpleStmt = ((returnStmt | raiseStmt | yieldStmt | discardStmt | breakStmt
  #|            | continueStmt | pragmaStmt | importStmt | exportStmt | fromStmt
  #|            | includeStmt | commentStmt) / exprStmt) COMMENT?
  #|
  case p.tok.tokType
  of tkReturn: result = parseReturnOrRaise(p, nkReturnStmt)
  of tkRaise: result = parseReturnOrRaise(p, nkRaiseStmt)
  of tkYield: result = parseReturnOrRaise(p, nkYieldStmt)
  of tkDiscard: result = parseReturnOrRaise(p, nkDiscardStmt)
  of tkBreak: result = parseReturnOrRaise(p, nkBreakStmt)
  of tkContinue: result = parseReturnOrRaise(p, nkContinueStmt)
  of tkCurlyDotLe: result = parseStmtPragma(p)
  of tkImport: result = parseImport(p, nkImportStmt)
  of tkExport: result = parseImport(p, nkExportStmt)
  of tkFrom: result = parseFromStmt(p)
  of tkInclude: result = parseIncludeStmt(p)
  of tkComment: result = newCommentStmt(p)
  else:
    if isExprStart(p): result = parseExprStmt(p)
    else: result = p.emptyNode
  if result.kind notin {nkEmpty, nkCommentStmt}: skipComment(p, result)

proc complexOrSimpleStmt(p: var TParser): PNode =
  #| complexOrSimpleStmt = (ifStmt | whenStmt | whileStmt
  #|                     | tryStmt | forStmt
  #|                     | blockStmt | staticStmt | deferStmt | asmStmt
  #|                     | 'proc' routine
  #|                     | 'method' routine
  #|                     | 'func' routine
  #|                     | 'iterator' routine
  #|                     | 'macro' routine
  #|                     | 'template' routine
  #|                     | 'converter' routine
  #|                     | 'type' section(typeDef)
  #|                     | 'const' section(constant)
  #|                     | ('let' | 'var' | 'using') section(variable)
  #|                     | bindStmt | mixinStmt)
  #|                     / simpleStmt
  case p.tok.tokType
  of tkIf: result = parseIfOrWhen(p, nkIfStmt)
  of tkWhile: result = parseWhile(p)
  of tkCase: result = parseCase(p)
  of tkTry: result = parseTry(p, isExpr=false)
  of tkFinally: result = parseExceptBlock(p, nkFinally)
  of tkExcept: result = parseExceptBlock(p, nkExceptBranch)
  of tkFor: result = parseFor(p)
  of tkBlock: result = parseBlock(p)
  of tkStatic: result = parseStaticOrDefer(p, nkStaticStmt)
  of tkDefer: result = parseStaticOrDefer(p, nkDefer)
  of tkAsm: result = parseAsm(p)
  of tkProc: result = parseRoutine(p, nkProcDef)
  of tkFunc: result = parseRoutine(p, nkFuncDef)
  of tkMethod: result = parseRoutine(p, nkMethodDef)
  of tkIterator: result = parseRoutine(p, nkIteratorDef)
  of tkMacro: result = parseRoutine(p, nkMacroDef)
  of tkTemplate: result = parseRoutine(p, nkTemplateDef)
  of tkConverter: result = parseRoutine(p, nkConverterDef)
  of tkType:
    getTok(p)
    if p.tok.tokType == tkParLe:
      getTok(p)
      result = newNodeP(nkTypeOfExpr, p)
      result.add(primary(p, pmTypeDesc))
      eat(p, tkParRi)
      result = parseOperators(p, result, -1, pmNormal)
    else:
      result = parseSection(p, nkTypeSection, parseTypeDef)
  of tkConst:
    prettySection:
      result = parseSection(p, nkConstSection, parseConstant)
  of tkLet:
    prettySection:
      result = parseSection(p, nkLetSection, parseVariable)
  of tkVar:
    prettySection:
      result = parseSection(p, nkVarSection, parseVariable)
  of tkWhen: result = parseIfOrWhen(p, nkWhenStmt)
  of tkBind: result = parseBind(p, nkBindStmt)
  of tkMixin: result = parseBind(p, nkMixinStmt)
  of tkUsing: result = parseSection(p, nkUsingStmt, parseVariable)
  else: result = simpleStmt(p)

proc parseStmt(p: var TParser): PNode =
  #| stmt = (IND{>} complexOrSimpleStmt^+(IND{=} / ';') DED)
  #|      / simpleStmt ^+ ';'
  if p.tok.indent > p.currInd:
    # nimpretty support here
    result = newNodeP(nkStmtList, p)
    withInd(p):
      while true:
        if p.tok.indent == p.currInd:
          discard
        elif p.tok.tokType == tkSemiColon:
          getTok(p)
          if p.tok.indent < 0 or p.tok.indent == p.currInd: discard
          else: break
        else:
          if p.tok.indent > p.currInd and p.tok.tokType != tkDot:
            parMessage(p, errInvalidIndentation)
          break
        if p.tok.tokType in {tkCurlyRi, tkParRi, tkCurlyDotRi, tkBracketRi}:
          # XXX this ensures tnamedparamanonproc still compiles;
          # deprecate this syntax later
          break
        p.hasProgress = false
        var a = complexOrSimpleStmt(p)
        if a.kind != nkEmpty:
          result.add(a)
        else:
          # This is done to make the new 'if' expressions work better.
          # XXX Eventually we need to be more strict here.
          if p.tok.tokType notin {tkElse, tkElif}:
            parMessage(p, errExprExpected, p.tok)
            getTok(p)
          else:
            break
        if not p.hasProgress and p.tok.tokType == tkEof: break
  else:
    # the case statement is only needed for better error messages:
    case p.tok.tokType
    of tkIf, tkWhile, tkCase, tkTry, tkFor, tkBlock, tkAsm, tkProc, tkFunc,
       tkIterator, tkMacro, tkType, tkConst, tkWhen, tkVar:
      parMessage(p, "complex statement requires indentation")
      result = p.emptyNode
    else:
      if p.inSemiStmtList > 0:
        result = simpleStmt(p)
        if result.kind == nkEmpty: parMessage(p, errExprExpected, p.tok)
      else:
        result = newNodeP(nkStmtList, p)
        while true:
          if p.tok.indent >= 0:
            parMessage(p, errInvalidIndentation)
          p.hasProgress = false
          let a = simpleStmt(p)
          let err = not p.hasProgress
          if a.kind == nkEmpty: parMessage(p, errExprExpected, p.tok)
          result.add(a)
          if p.tok.tokType != tkSemiColon: break
          getTok(p)
          if err and p.tok.tokType == tkEof: break

proc parseAll(p: var TParser): PNode =
  ## Parses the rest of the input stream held by the parser into a PNode.
  result = newNodeP(nkStmtList, p)
  while p.tok.tokType != tkEof:
    p.hasProgress = false
    var a = complexOrSimpleStmt(p)
    if a.kind != nkEmpty and p.hasProgress:
      result.add(a)
    else:
      parMessage(p, errExprExpected, p.tok)
      # bugfix: consume a token here to prevent an endless loop:
      getTok(p)
    if p.tok.indent != 0:
      parMessage(p, errInvalidIndentation)

proc parseTopLevelStmt(p: var TParser): PNode =
  ## Implements an iterator which, when called repeatedly, returns the next
  ## top-level statement or emptyNode if end of stream.
  result = p.emptyNode
  # progress guaranteed
  while true:
    # nimpretty support here
    if p.tok.indent != 0:
      if p.firstTok and p.tok.indent < 0: discard
      elif p.tok.tokType != tkSemiColon:
        # special casing for better error messages:
        if p.tok.tokType == tkOpr and p.tok.ident.s == "*":
          parMessage(p, errGenerated,
            "invalid indentation; an export marker '*' follows the declared identifier")
        else:
          parMessage(p, errInvalidIndentation)
    p.firstTok = false
    case p.tok.tokType
    of tkSemiColon:
      getTok(p)
      if p.tok.indent <= 0: discard
      else: parMessage(p, errInvalidIndentation)
      p.firstTok = true
    of tkEof: break
    else:
      result = complexOrSimpleStmt(p)
      if result.kind == nkEmpty: parMessage(p, errExprExpected, p.tok)
      break

proc parseString*(s: string; cache: IdentCache; config: ConfigRef;
                  filename: string = ""; line: int = 0;
                  errorHandler: TErrorHandler = nil): PNode =
  ## Parses a string into an AST, returning the top node.
  ## `filename` and `line`, although optional, provide info so that the
  ## compiler can generate correct error messages referring to the original
  ## source.
  var stream = newStringStream(s)
  # stream.lineOffset = line

  var parser: TParser
  parser.lex.errorHandler = errorHandler
  openParser(parser, AbsoluteFile filename, stream, cache,config)

  result = parser.parseAll
  closeParser(parser)
