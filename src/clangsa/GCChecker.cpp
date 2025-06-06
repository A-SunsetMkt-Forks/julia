// This file is a part of Julia. License is MIT: https://julialang.org/license

#include "clang/AST/Type.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/StaticAnalyzer/Checkers/SValExplainer.h"
#include "clang/StaticAnalyzer/Core/BugReporter/BugType.h"
#include "clang/StaticAnalyzer/Core/BugReporter/CommonBugCategories.h"
#include "clang/StaticAnalyzer/Core/Checker.h"
#include "clang/StaticAnalyzer/Core/PathSensitive/CallEvent.h"
#include "clang/StaticAnalyzer/Core/PathSensitive/CheckerContext.h"
#include "clang/StaticAnalyzer/Core/PathSensitive/SVals.h"
#include "clang/StaticAnalyzer/Frontend/AnalysisConsumer.h"
#include "clang/StaticAnalyzer/Frontend/FrontendActions.h"
#include "clang/Tooling/CompilationDatabase.h"
#include "clang/Tooling/Tooling.h"
#include "clang/StaticAnalyzer/Frontend/CheckerRegistry.h"

#include "llvm/Support/Debug.h"
#include <iostream>
#include <memory>

#if defined(__GNUC__)
#define USED_FUNC __attribute__((used))
#else
#define USED_FUNC
#endif

using std::make_unique;

namespace {
using namespace clang;
using namespace ento;

typedef std::shared_ptr<PathDiagnosticPiece> PDP;
#define MakePDP make_unique<PathDiagnosticEventPiece>

static const Stmt *getStmtForDiagnostics(const ExplodedNode *N)
{
    return N->getStmtForDiagnostics();
}

static unsigned getStackFrameHeight(const LocationContext *stack)
{
    // TODO: or use getID ?
    unsigned depth = 0;
    while (stack) {
        depth++;
        stack = stack->getParent();
    }
    return depth;
}

class GCChecker
    : public Checker<
          eval::Call,
          check::BeginFunction,
          check::EndFunction,
          check::PostCall,
          check::PreCall,
          check::PostStmt<CStyleCastExpr>,
          check::PostStmt<ArraySubscriptExpr>,
          check::PostStmt<MemberExpr>,
          check::PostStmt<UnaryOperator>,
          check::Bind,
          check::Location> {
  mutable std::unique_ptr<BugType> BT;
  template <typename callback>
  void report_error(callback f, CheckerContext &C, StringRef message) const;
  void report_error(CheckerContext &C, StringRef message) const {
    return report_error([](PathSensitiveBugReport *) {}, C, message);
  }
  void
  report_value_error(CheckerContext &C, SymbolRef Sym, const char *message,
                     clang::SourceRange range = clang::SourceRange()) const;

public:
  struct ValueState {
    enum State { Allocated, Rooted, PotentiallyFreed, Untracked } S;
    const MemRegion *Root;
    int RootDepth;

    // Optional Metadata (for error messages)
    const FunctionDecl *FD;
    const ParmVarDecl *PVD;

    ValueState(State InS, const MemRegion *Root, int Depth)
        : S(InS), Root(Root), RootDepth(Depth), FD(nullptr), PVD(nullptr) {}
    ValueState()
        : S(Untracked), Root(nullptr), RootDepth(0), FD(nullptr), PVD(nullptr) {
    }

    USED_FUNC void dump() const {
      llvm::dbgs() << ((S == Allocated) ? "Allocated"
                     : (S == Rooted) ? "Rooted"
                     : (S == PotentiallyFreed) ? "PotentiallyFreed"
                     : (S == Untracked) ? "Untracked"
                     : "Error");
      if (S == Rooted)
        llvm::dbgs() << "(" << RootDepth << ")";
      llvm::dbgs() << "\n";
    }

    bool operator==(const ValueState &VS) const {
      return S == VS.S && Root == VS.Root && RootDepth == VS.RootDepth;
    }
    bool operator!=(const ValueState &VS) const {
      return S != VS.S || Root != VS.Root || RootDepth != VS.RootDepth;
    }

    void Profile(llvm::FoldingSetNodeID &ID) const {
      ID.AddInteger(S);
      ID.AddPointer(Root);
      ID.AddInteger(RootDepth);
    }

    bool isRooted() const { return S == Rooted; }
    bool isPotentiallyFreed() const { return S == PotentiallyFreed; }
    bool isJustAllocated() const { return S == Allocated; }
    bool isUntracked() const { return S == Untracked; }

    bool isRootedBy(const MemRegion *R) const {
      assert(R != nullptr);
      return isRooted() && R == Root;
    }

    static ValueState getAllocated() {
      return ValueState(Allocated, nullptr, -1);
    }
    static ValueState getFreed() {
      return ValueState(PotentiallyFreed, nullptr, -1);
    }
    static ValueState getUntracked() {
      return ValueState(Untracked, nullptr, -1);
    }
    static ValueState getRooted(const MemRegion *Root, int Depth) {
      return ValueState(Rooted, Root, Depth);
    }
    static ValueState getForArgument(const FunctionDecl *FD,
                                     const ParmVarDecl *PVD,
                                     bool isFunctionSafepoint) {
      bool maybeUnrooted = declHasAnnotation(PVD, "julia_maybe_unrooted");
      if (!isFunctionSafepoint || maybeUnrooted) {
        ValueState VS = getAllocated();
        VS.PVD = PVD;
        VS.FD = FD;
        return VS;
      }
      return getRooted(nullptr, -1);
    }
  };

  struct RootState {
    enum Kind { Root, RootArray } K;
    int RootedAtDepth;

    RootState(Kind InK, int Depth) : K(InK), RootedAtDepth(Depth) {}

    bool operator==(const RootState &VS) const {
      return K == VS.K && RootedAtDepth == VS.RootedAtDepth;
    }
    bool operator!=(const RootState &VS) const {
      return K != VS.K || RootedAtDepth != VS.RootedAtDepth;
    }

    bool shouldPopAtDepth(int Depth) const { return Depth == RootedAtDepth; }
    bool isRootArray() const { return K == RootArray; }

    void Profile(llvm::FoldingSetNodeID &ID) const {
      ID.AddInteger(K);
      ID.AddInteger(RootedAtDepth);
    }

    static RootState getRoot(int Depth) { return RootState(Root, Depth); }
    static RootState getRootArray(int Depth) {
      return RootState(RootArray, Depth);
    }
  };

private:
  template <typename callback>
  static bool isJuliaType(callback f, QualType QT) {
    if (QT->isPointerType() || QT->isArrayType())
      return isJuliaType(
          f, clang::QualType(QT->getPointeeOrArrayElementType(), 0));
    const TypedefType *TT = QT->getAs<TypedefType>();
    if (TT) {
      if (f(TT->getDecl()->getName()))
        return true;
    }
    const TagDecl *TD = QT->getUnqualifiedDesugaredType()->getAsTagDecl();
    if (!TD) {
      return false;
    }
    return f(TD->getName());
  }
  template <typename callback>
  static SymbolRef walkToRoot(callback f, const ProgramStateRef &State,
                              const MemRegion *Region);

  static bool isGCTrackedType(QualType Type);
  static bool isGCTracked(const Expr *E);
  bool isGloballyRootedType(QualType Type) const;
  static void dumpState(const ProgramStateRef &State);
  static const AnnotateAttr *declHasAnnotation(const clang::Decl *D, const char *which);
  static bool isFDAnnotatedNotSafepoint(const clang::FunctionDecl *FD, const SourceManager &SM);
  static const SourceManager &getSM(CheckerContext &C) { return C.getSourceManager(); }
  bool isSafepoint(const CallEvent &Call, CheckerContext &C) const;
  bool processPotentialSafepoint(const CallEvent &Call, CheckerContext &C,
                                 ProgramStateRef &State) const;
  bool processAllocationOfResult(const CallEvent &Call, CheckerContext &C,
                                 ProgramStateRef &State) const;
  bool processArgumentRooting(const CallEvent &Call, CheckerContext &C,
                              ProgramStateRef &State) const;
  bool rootRegionIfGlobal(const MemRegion *R, ProgramStateRef &,
                          CheckerContext &C, ValueState *ValS = nullptr) const;
  static const ValueState *getValStateForRegion(ASTContext &AstC,
                                                const ProgramStateRef &State,
                                                const MemRegion *R,
                                                bool Debug = false);
  bool gcEnabledHere(CheckerContext &C) const;
  bool gcEnabledHere(ProgramStateRef State) const;
  bool safepointEnabledHere(CheckerContext &C) const;
  bool safepointEnabledHere(ProgramStateRef State) const;
  bool propagateArgumentRootedness(CheckerContext &C,
                                   ProgramStateRef &State) const;
  SymbolRef getSymbolForResult(const Expr *Result, const ValueState *OldValS,
                               ProgramStateRef &State, CheckerContext &C) const;

public:
  void checkBeginFunction(CheckerContext &Ctx) const;
  void checkEndFunction(const clang::ReturnStmt *RS, CheckerContext &Ctx) const;
  bool evalCall(const CallEvent &Call, CheckerContext &C) const;
  void checkPreCall(const CallEvent &Call, CheckerContext &C) const;
  void checkPostCall(const CallEvent &Call, CheckerContext &C) const;
  void checkPostStmt(const CStyleCastExpr *CE, CheckerContext &C) const;
  void checkPostStmt(const ArraySubscriptExpr *CE, CheckerContext &C) const;
  void checkPostStmt(const MemberExpr *ME, CheckerContext &C) const;
  void checkPostStmt(const UnaryOperator *UO, CheckerContext &C) const;
  void checkDerivingExpr(const Expr *Result, const Expr *Parent,
                         bool ParentIsLoc, CheckerContext &C) const;
  void checkBind(SVal Loc, SVal Val, const Stmt *S, CheckerContext &) const;
  void checkLocation(SVal Loc, bool IsLoad, const Stmt *S,
                     CheckerContext &) const;
  class GCBugVisitor : public BugReporterVisitor {
  public:
    GCBugVisitor() {}

    void Profile(llvm::FoldingSetNodeID &ID) const override {
      static int X = 0;
      ID.AddPointer(&X);
    }

    PDP VisitNode(const ExplodedNode *N, BugReporterContext &BRC, PathSensitiveBugReport &BR) override;
  };

  class SafepointBugVisitor : public BugReporterVisitor {
  public:
    SafepointBugVisitor() {}

    void Profile(llvm::FoldingSetNodeID &ID) const override {
      static int X = 0;
      ID.AddPointer(&X);
    }

    PDP VisitNode(const ExplodedNode *N, BugReporterContext &BRC, PathSensitiveBugReport &BR) override;
  };

  class GCValueBugVisitor : public BugReporterVisitor {
  protected:
    SymbolRef Sym;

  public:
    GCValueBugVisitor(SymbolRef S) : Sym(S) {}

    void Profile(llvm::FoldingSetNodeID &ID) const override {
      static int X = 0;
      ID.AddPointer(&X);
      ID.AddPointer(Sym);
    }

    PDP ExplainNoPropagation(const ExplodedNode *N, PathDiagnosticLocation Pos,
                             BugReporterContext &BRC, PathSensitiveBugReport &BR);
    PDP ExplainNoPropagationFromExpr(const clang::Expr *FromWhere,
                                     const ExplodedNode *N,
                                     PathDiagnosticLocation Pos,
                                     BugReporterContext &BRC, PathSensitiveBugReport &BR);

    PDP VisitNode(const ExplodedNode *N, BugReporterContext &BRC, PathSensitiveBugReport &BR) override;
  }; // namespace
};

} // namespace

REGISTER_TRAIT_WITH_PROGRAMSTATE(GCDepth, unsigned)
REGISTER_TRAIT_WITH_PROGRAMSTATE(GCDisabledAt, unsigned)
REGISTER_TRAIT_WITH_PROGRAMSTATE(SafepointDisabledAt, unsigned)
REGISTER_TRAIT_WITH_PROGRAMSTATE(MayCallSafepoint, bool)
REGISTER_MAP_WITH_PROGRAMSTATE(GCValueMap, SymbolRef, GCChecker::ValueState)
REGISTER_MAP_WITH_PROGRAMSTATE(GCRootMap, const MemRegion *,
                               GCChecker::RootState)

template <typename callback>
SymbolRef GCChecker::walkToRoot(callback f, const ProgramStateRef &State,
                                const MemRegion *Region) {
  if (!Region)
    return nullptr;
  while (true) {
    const SymbolicRegion *SR = Region->getSymbolicBase();
    if (!SR) {
      return nullptr;
    }
    SymbolRef Sym = SR->getSymbol();
    const ValueState *OldVState = State->get<GCValueMap>(Sym);
    if (f(Sym, OldVState)) {
      if (const SymbolRegionValue *SRV = dyn_cast<SymbolRegionValue>(Sym)) {
        Region = SRV->getRegion();
        continue;
      } else if (const SymbolDerived *SD = dyn_cast<SymbolDerived>(Sym)) {
        Region = SD->getRegion();
        continue;
      }
      return nullptr;
    }
    return Sym;
  }
}

namespace Helpers {
static const VarRegion *walk_back_to_global_VR(const MemRegion *Region) {
  if (!Region)
    return nullptr;
  while (true) {
    const VarRegion *VR = Region->getAs<VarRegion>();
    if (VR && VR->getDecl()->hasGlobalStorage()) {
      return VR;
    }
    const SymbolicRegion *SymR = Region->getAs<SymbolicRegion>();
    if (SymR) {
      const SymbolRegionValue *SymRV =
          dyn_cast<SymbolRegionValue>(SymR->getSymbol());
      if (!SymRV) {
        const SymbolDerived *SD = dyn_cast<SymbolDerived>(SymR->getSymbol());
        if (SD) {
          Region = SD->getRegion();
          continue;
        }
        break;
      }
      Region = SymRV->getRegion();
      continue;
    }
    const SubRegion *SR = Region->getAs<SubRegion>();
    if (!SR)
      break;
    Region = SR->getSuperRegion();
  }
  return nullptr;
}
} // namespace Helpers

PDP GCChecker::GCBugVisitor::VisitNode(const ExplodedNode *N,
                                       BugReporterContext &BRC, PathSensitiveBugReport &BR) {
  const ExplodedNode *PrevN = N->getFirstPred();
  unsigned NewGCDepth = N->getState()->get<GCDepth>();
  unsigned OldGCDepth = PrevN->getState()->get<GCDepth>();
  if (NewGCDepth != OldGCDepth) {
    PathDiagnosticLocation Pos(getStmtForDiagnostics(N),
                               BRC.getSourceManager(), N->getLocationContext());
    return MakePDP(Pos, "GC frame changed here.");
  }
  unsigned NewGCState = N->getState()->get<GCDisabledAt>();
  unsigned OldGCState = PrevN->getState()->get<GCDisabledAt>();
  if (false /*NewGCState != OldGCState*/) {
    PathDiagnosticLocation Pos(getStmtForDiagnostics(N),
                               BRC.getSourceManager(), N->getLocationContext());
    return MakePDP(Pos, "GC enabledness changed here.");
  }
  return nullptr;
}

PDP GCChecker::SafepointBugVisitor::VisitNode(const ExplodedNode *N,
                                       BugReporterContext &BRC, PathSensitiveBugReport &BR) {
  const ExplodedNode *PrevN = N->getFirstPred();
  unsigned NewSafepointDisabled = N->getState()->get<SafepointDisabledAt>();
  unsigned OldSafepointDisabled = PrevN->getState()->get<SafepointDisabledAt>();
  if (NewSafepointDisabled != OldSafepointDisabled) {
    const Decl *D = &N->getCodeDecl();
    const AnnotateAttr *Ann = declHasAnnotation(D, "julia_not_safepoint");
    PathDiagnosticLocation Pos;
    if (OldSafepointDisabled == (unsigned)-1) {
      if (Ann) {
        Pos = PathDiagnosticLocation{Ann->getLoc(), BRC.getSourceManager()};
        return MakePDP(Pos, "Tracking JL_NOT_SAFEPOINT annotation here.");
      } else {
        PathDiagnosticLocation Pos = PathDiagnosticLocation::createDeclBegin(
            N->getLocationContext(), BRC.getSourceManager());
        if (Pos.isValid())
          return MakePDP(Pos, "Tracking JL_NOT_SAFEPOINT annotation here.");
        //N->getLocation().dump();
      }
    } else if (NewSafepointDisabled == (unsigned)-1) {
      PathDiagnosticLocation Pos = PathDiagnosticLocation::createDeclBegin(
          N->getLocationContext(), BRC.getSourceManager());
      if (Pos.isValid())
        return MakePDP(Pos, "Safepoints re-enabled here");
      //N->getLocation().dump();
    }
    // n.b. there may be no position here to report if they were disabled by julia_notsafepoint_enter/leave
  }
  return nullptr;
}

PDP GCChecker::GCValueBugVisitor::ExplainNoPropagationFromExpr(
    const clang::Expr *FromWhere, const ExplodedNode *N,
    PathDiagnosticLocation Pos, BugReporterContext &BRC, PathSensitiveBugReport &BR) {
  const MemRegion *Region =
      N->getState()->getSVal(FromWhere, N->getLocationContext()).getAsRegion();
  SymbolRef Parent = walkToRoot(
      [&](SymbolRef Sym, const ValueState *OldVState) { return !OldVState; },
      N->getState(), Region);
  if (!Parent && Region) {
    Parent = walkToRoot(
        [&](SymbolRef Sym, const ValueState *OldVState) { return !OldVState; },
        N->getState(), N->getState()->getSVal(Region).getAsRegion());
  }
  if (!Parent) {
    // May have been derived from a global. Check that
    const VarRegion *VR = Helpers::walk_back_to_global_VR(Region);
    if (VR) {
      BR.addNote("Derivation root was here",
                 PathDiagnosticLocation::create(VR->getDecl(),
                                                BRC.getSourceManager()));
      const VarDecl *VD = VR->getDecl();
      if (VD) {
        if (!declHasAnnotation(VD, "julia_globally_rooted")) {
          return MakePDP(Pos, "Argument value was derived from unrooted "
                              "global. May need GLOBALLY_ROOTED annotation.");
        } else if (!isGCTrackedType(VD->getType())) {
          return MakePDP(
              Pos, "Argument value was derived global with untracked type. You "
                   "may want to update the checker's type list");
        }
      }
      return MakePDP(Pos,
                     "Argument value was derived from global, but the checker "
                     "did not propagate the root. This may be a bug");
    }
    return MakePDP(Pos,
                   "Could not propagate root. Argument value was untracked.");
  }
  const ValueState *ValS = N->getState()->get<GCValueMap>(Parent);
  assert(ValS);
  if (ValS->isPotentiallyFreed()) {
    BR.addVisitor(make_unique<GCValueBugVisitor>(Parent));
    return MakePDP(
        Pos, "Root not propagated because it may have been freed. Tracking.");
  } else if (ValS->isRooted()) {
    BR.addVisitor(make_unique<GCValueBugVisitor>(Parent));
    return MakePDP(
        Pos, "Root was not propagated due to a bug. Tracking base value.");
  } else {
    BR.addVisitor(make_unique<GCValueBugVisitor>(Parent));
    return MakePDP(Pos, "No Root to propagate. Tracking.");
  }
}

PDP GCChecker::GCValueBugVisitor::ExplainNoPropagation(
    const ExplodedNode *N, PathDiagnosticLocation Pos, BugReporterContext &BRC,
    PathSensitiveBugReport &BR) {
  if (N->getLocation().getAs<StmtPoint>()) {
    const clang::Stmt *TheS = N->getLocation().castAs<StmtPoint>().getStmt();
    const clang::CallExpr *CE = dyn_cast<CallExpr>(TheS);
    const clang::MemberExpr *ME = dyn_cast<MemberExpr>(TheS);
    if (ME)
      return ExplainNoPropagationFromExpr(ME->getBase(), N, Pos, BRC, BR);
    const clang::ArraySubscriptExpr *ASE = dyn_cast<ArraySubscriptExpr>(TheS);
    if (ASE)
      return ExplainNoPropagationFromExpr(ASE->getLHS(), N, Pos, BRC, BR);
    if (!CE)
      return nullptr;
    const clang::FunctionDecl *FD = CE->getDirectCallee();
    if (!FD)
      return nullptr;
    for (unsigned i = 0; i < FD->getNumParams(); ++i) {
      if (!declHasAnnotation(FD->getParamDecl(i), "julia_propagates_root"))
        continue;
      return ExplainNoPropagationFromExpr(CE->getArg(i), N, Pos, BRC, BR);
    }
    return nullptr;
  }
  return nullptr;
}

PDP GCChecker::GCValueBugVisitor::VisitNode(const ExplodedNode *N,
                                            BugReporterContext &BRC, PathSensitiveBugReport &BR) {
  const ExplodedNode *PrevN = N->getFirstPred();
  const ValueState *NewValueState = N->getState()->get<GCValueMap>(Sym);
  const ValueState *OldValueState = PrevN->getState()->get<GCValueMap>(Sym);
  const Stmt *Stmt = getStmtForDiagnostics(N);

  PathDiagnosticLocation Pos;
  if (Stmt)
    Pos = PathDiagnosticLocation{Stmt, BRC.getSourceManager(),
                                 N->getLocationContext()};
  else
    Pos = PathDiagnosticLocation::createDeclEnd(N->getLocationContext(),
                                                BRC.getSourceManager());
  if (!NewValueState)
    return nullptr;
  if (!OldValueState) {
    if (NewValueState->isRooted()) {
      return MakePDP(Pos, "Started tracking value here (root was inherited).");
    } else {
      if (NewValueState->FD) {
        bool isFunctionSafepoint =
            !isFDAnnotatedNotSafepoint(NewValueState->FD, BRC.getSourceManager());
        bool maybeUnrooted =
            declHasAnnotation(NewValueState->PVD, "julia_maybe_unrooted");
        assert(isFunctionSafepoint || maybeUnrooted);
        (void)maybeUnrooted;
        Pos =
            PathDiagnosticLocation{NewValueState->PVD, BRC.getSourceManager()};
        if (!isFunctionSafepoint)
          return MakePDP(Pos, "Argument not rooted, because function was "
                              "annotated as not a safepoint");
        else
          return MakePDP(Pos, "Argument was annotated as MAYBE_UNROOTED.");
      } else {
        PDP Diag = ExplainNoPropagation(N, Pos, BRC, BR);
        if (Diag)
          return Diag;
        return MakePDP(Pos, "Started tracking value here.");
      }
    }
  }
  if (!OldValueState->isUntracked() && NewValueState->isUntracked()) {
    PDP Diag = ExplainNoPropagation(N, Pos, BRC, BR);
    if (Diag)
      return Diag;
    return MakePDP(Pos, "Created untracked derivative.");
  } else if (NewValueState->isPotentiallyFreed() &&
             OldValueState->isJustAllocated()) {
    // std::make_shared< in later LLVM
    return MakePDP(Pos, "Value may have been GCed here.");
  } else if (NewValueState->isPotentiallyFreed() &&
             !OldValueState->isPotentiallyFreed()) {
    // std::make_shared< in later LLVM
    return MakePDP(Pos,
                   "Value may have been GCed here (though I don't know why).");
  } else if (NewValueState->isRooted() && OldValueState->isJustAllocated()) {
    return MakePDP(Pos, "Value was rooted here.");
  } else if (!NewValueState->isRooted() && OldValueState->isRooted()) {
    return MakePDP(Pos, "Root was released here.");
  } else if (NewValueState->RootDepth != OldValueState->RootDepth) {
    return MakePDP(Pos, "Rooting Depth changed here.");
  }
  return nullptr;
}

template <typename callback>
void GCChecker::report_error(callback f, CheckerContext &C,
                             StringRef message) const {
  // Generate an error node.
  ExplodedNode *N = C.generateErrorNode();
  if (!N)
    return;

  if (!BT)
    BT.reset(new BugType(this, "Invalid GC thingy", categories::LogicError));
  auto Report = make_unique<PathSensitiveBugReport>(*BT, message, N);
  Report->addVisitor(make_unique<GCBugVisitor>());
  f(Report.get());
  C.emitReport(std::move(Report));
}

void GCChecker::report_value_error(CheckerContext &C, SymbolRef Sym,
                                   const char *message,
                                   SourceRange range) const {
  // Generate an error node.
  ExplodedNode *N = C.generateErrorNode();
  if (!N)
    return;

  if (!BT)
    BT.reset(new BugType(this, "Invalid GC thingy", categories::LogicError));
  auto Report = make_unique<PathSensitiveBugReport>(*BT, message, N);
  Report->addVisitor(make_unique<GCValueBugVisitor>(Sym));
  Report->addVisitor(make_unique<GCBugVisitor>());
  Report->addVisitor(make_unique<ConditionBRVisitor>());
  if (!range.isInvalid()) {
    Report->addRange(range);
  }
  C.emitReport(std::move(Report));
}

bool GCChecker::gcEnabledHere(CheckerContext &C) const {
  return gcEnabledHere(C.getState());
}

bool GCChecker::gcEnabledHere(ProgramStateRef State) const {
  unsigned disabledAt = State->get<GCDisabledAt>();
  return disabledAt == (unsigned)-1;
}

bool GCChecker::safepointEnabledHere(CheckerContext &C) const {
    return safepointEnabledHere(C.getState());
}

bool GCChecker::safepointEnabledHere(ProgramStateRef State) const {
  unsigned disabledAt = State->get<SafepointDisabledAt>();
  return disabledAt == (unsigned)-1;
}

bool GCChecker::propagateArgumentRootedness(CheckerContext &C,
                                            ProgramStateRef &State) const {
  const auto *LCtx = C.getLocationContext();

  const auto *Site = cast<StackFrameContext>(LCtx)->getCallSite();
  if (!Site)
    return false;

  const auto *FD = dyn_cast<FunctionDecl>(LCtx->getDecl());
  if (!FD)
    return false;

  const auto *CE = dyn_cast<CallExpr>(Site);
  if (!CE)
    return false;

  // FD->dump();

  bool Change = false;
  int idx = 0;
  for (const auto P : FD->parameters()) {
    if (!isGCTrackedType(P->getType())) {
      continue;
    }
    auto Arg = State->getSVal(CE->getArg(idx++), LCtx->getParent());
    SymbolRef ArgSym = walkToRoot(
        [](SymbolRef Sym, const ValueState *OldVState) { return !OldVState; },
        State, Arg.getAsRegion());
    if (!ArgSym) {
      continue;
    }
    const ValueState *ValS = State->get<GCValueMap>(ArgSym);
    if (!ValS) {
      report_error(
          [&](PathSensitiveBugReport *Report) {
            Report->addNote(
                "Tried to find root for this parameter in inlined call",
                PathDiagnosticLocation::create(P, C.getSourceManager()));
          },
          C, "Missed allocation of parameter");
      continue;
    }
    auto Param = State->getLValue(P, LCtx);
    SymbolRef ParamSym = State->getSVal(Param).getAsSymbol();
    if (!ParamSym) {
      continue;
    }
    if (isGloballyRootedType(P->getType())) {
      State =
          State->set<GCValueMap>(ParamSym, ValueState::getRooted(nullptr, -1));
      Change = true;
      continue;
    }
    State = State->set<GCValueMap>(ParamSym, *ValS);
    Change = true;
  }
  return Change;
}

void GCChecker::checkBeginFunction(CheckerContext &C) const {
  // Consider top-level argument values rooted, unless an annotation says
  // otherwise
  const auto *LCtx = C.getLocationContext();
  const auto *FD = dyn_cast<FunctionDecl>(LCtx->getDecl());
  assert(FD);
  unsigned CurrentHeight = getStackFrameHeight(C.getStackFrame());
  ProgramStateRef State = C.getState();
  bool Change = false;
  if (C.inTopFrame()) {
    State = State->set<GCDisabledAt>((unsigned)-1);
    State = State->set<SafepointDisabledAt>((unsigned)-1);
    Change = true;
  }
  if (gcEnabledHere(State) && declHasAnnotation(FD, "julia_gc_disabled")) {
    State = State->set<GCDisabledAt>(CurrentHeight);
    Change = true;
  }
  bool isFunctionSafepoint = !isFDAnnotatedNotSafepoint(FD, getSM(C));
  if (safepointEnabledHere(State) &&
      (!isFunctionSafepoint || declHasAnnotation(FD, "julia_notsafepoint_leave"))) {
    State = State->set<SafepointDisabledAt>(CurrentHeight);
    Change = true;
  }
  if (!C.inTopFrame()) {
    if (propagateArgumentRootedness(C, State) || Change)
      C.addTransition(State);
    return;
  }
  for (const auto P : FD->parameters()) {
    if (declHasAnnotation(P, "julia_require_rooted_slot")) {
      auto Param = State->getLValue(P, LCtx);
      const MemRegion *Root = State->getSVal(Param).getAsRegion();
      State = State->set<GCRootMap>(Root, RootState::getRoot(-1));
    } else if (isGCTrackedType(P->getType())) {
      auto Param = State->getLValue(P, LCtx);
      SymbolRef AssignedSym = State->getSVal(Param).getAsSymbol();
      if (!AssignedSym)
        continue;
      assert(AssignedSym);
      State = State->set<GCValueMap>(AssignedSym,
                                     ValueState::getForArgument(FD, P, isFunctionSafepoint));
      Change = true;
    }
  }
  if (Change) {
    C.addTransition(State);
  }
}

void GCChecker::checkEndFunction(const clang::ReturnStmt *RS,
                                 CheckerContext &C) const {
  ProgramStateRef State = C.getState();
  const auto *LCtx = C.getLocationContext();
  const auto *FD = dyn_cast<FunctionDecl>(LCtx->getDecl());

  if (RS && gcEnabledHere(State) && RS->getRetValue() && isGCTracked(RS->getRetValue())) {
    auto ResultVal = C.getSVal(RS->getRetValue());
    SymbolRef Sym = ResultVal.getAsSymbol(true);
    const ValueState *ValS = Sym ? State->get<GCValueMap>(Sym) : nullptr;
    if (ValS && ValS->isPotentiallyFreed()) {
      report_value_error(C, Sym, "Return value may have been GCed", RS->getSourceRange());
    }
  }

  unsigned CurrentHeight = getStackFrameHeight(C.getStackFrame());
  bool Changed = false;
  if (State->get<GCDisabledAt>() == CurrentHeight) {
    State = State->set<GCDisabledAt>((unsigned)-1);
    Changed = true;
  }
  if (State->get<SafepointDisabledAt>() == CurrentHeight) {
    if (!isFDAnnotatedNotSafepoint(FD, getSM(C)) && !(FD && declHasAnnotation(FD, "julia_notsafepoint_enter"))) {
      report_error(C, "Safepoints disabled at end of function");
    }
    State = State->set<SafepointDisabledAt>((unsigned)-1);
    Changed = true;
  }
  if (Changed)
    C.addTransition(State);
  if (!C.inTopFrame())
    return;
  unsigned CurrentDepth = C.getState()->get<GCDepth>();
  if (CurrentDepth != 0) {
    report_error(C, "Non-popped GC frame present at end of function");
  }
}

const AnnotateAttr *GCChecker::declHasAnnotation(const clang::Decl *D, const char *which) {
  for (const auto *Ann : D->specific_attrs<AnnotateAttr>()) {
    if (Ann->getAnnotation() == which)
      return Ann;
  }
  return nullptr;
}

bool GCChecker::isFDAnnotatedNotSafepoint(const clang::FunctionDecl *FD, const SourceManager &SM) {
  if (declHasAnnotation(FD, "julia_not_safepoint"))
      return true;
  SourceLocation Loc = FD->getLocation();
  StringRef Name = SM.getFilename(Loc);
  Name = llvm::sys::path::filename(Name);
  if (Name.starts_with("llvm-"))
      return true;
  return false;
}

static bool isMutexLock(StringRef name) {
    return name == "uv_mutex_lock" ||
           name == "uv_mutex_trylock" ||
           name == "pthread_mutex_lock" ||
           name == "pthread_mutex_trylock" ||
           name == "__gthread_mutex_lock" ||
           name == "__gthread_mutex_trylock" ||
           name == "__gthread_recursive_mutex_lock" ||
           name == "__gthread_recursive_mutex_trylock" ||
           name == "pthread_spin_lock" ||
           name == "pthread_spin_trylock" ||
           name == "uv_rwlock_rdlock" ||
           name == "uv_rwlock_tryrdlock" ||
           name == "uv_rwlock_wrlock" ||
           name == "uv_rwlock_trywrlock" ||
           false;
}

static bool isMutexUnlock(StringRef name) {
    return name == "uv_mutex_unlock" ||
           name == "pthread_mutex_unlock" ||
           name == "__gthread_mutex_unlock" ||
           name == "__gthread_recursive_mutex_unlock" ||
           name == "pthread_spin_unlock" ||
           name == "uv_rwlock_rdunlock" ||
           name == "uv_rwlock_wrunlock" ||
           false;
}


bool GCChecker::isGCTrackedType(QualType QT) {
  return isJuliaType(
             [](StringRef Name) {
               if (Name.ends_with_insensitive("jl_value_t") ||
                   Name.ends_with_insensitive("jl_svec_t") ||
                   Name.ends_with_insensitive("jl_sym_t") ||
                   Name.ends_with_insensitive("jl_expr_t") ||
                   Name.ends_with_insensitive("jl_code_info_t") ||
                   Name.ends_with_insensitive("jl_array_t") ||
                   Name.ends_with_insensitive("jl_genericmemory_t") ||
                   //Name.ends_with_insensitive("jl_genericmemoryref_t") ||
                   Name.ends_with_insensitive("jl_method_t") ||
                   Name.ends_with_insensitive("jl_method_instance_t") ||
                   Name.ends_with_insensitive("jl_debuginfo_t") ||
                   Name.ends_with_insensitive("jl_tupletype_t") ||
                   Name.ends_with_insensitive("jl_datatype_t") ||
                   Name.ends_with_insensitive("jl_typemap_entry_t") ||
                   Name.ends_with_insensitive("jl_typemap_level_t") ||
                   Name.ends_with_insensitive("jl_typename_t") ||
                   Name.ends_with_insensitive("jl_module_t") ||
                   Name.ends_with_insensitive("jl_tupletype_t") ||
                   Name.ends_with_insensitive("jl_gc_tracked_buffer_t") ||
                   Name.ends_with_insensitive("jl_binding_t") ||
                   Name.ends_with_insensitive("jl_binding_partition_t") ||
                   Name.ends_with_insensitive("jl_ordereddict_t") ||
                   Name.ends_with_insensitive("jl_tvar_t") ||
                   Name.ends_with_insensitive("jl_typemap_t") ||
                   Name.ends_with_insensitive("jl_unionall_t") ||
                   Name.ends_with_insensitive("jl_methtable_t") ||
                   Name.ends_with_insensitive("jl_methcache_t") ||
                   Name.ends_with_insensitive("jl_cgval_t") ||
                   Name.ends_with_insensitive("jl_codectx_t") ||
                   Name.ends_with_insensitive("jl_ast_context_t") ||
                   Name.ends_with_insensitive("jl_code_instance_t") ||
                   Name.ends_with_insensitive("jl_excstack_t") ||
                   Name.ends_with_insensitive("jl_task_t") ||
                   Name.ends_with_insensitive("jl_uniontype_t") ||
                   Name.ends_with_insensitive("jl_method_match_t") ||
                   Name.ends_with_insensitive("jl_vararg_t") ||
                   Name.ends_with_insensitive("jl_opaque_closure_t") ||
                   Name.ends_with_insensitive("jl_globalref_t") ||
                   Name.ends_with_insensitive("jl_abi_override_t") ||
                   // Probably not technically true for these, but let's allow it as a root
                   Name.ends_with_insensitive("jl_ircode_state") ||
                   Name.ends_with_insensitive("typemap_intersection_env") ||
                   Name.ends_with_insensitive("interpreter_state") ||
                   Name.ends_with_insensitive("jl_typeenv_t") ||
                   Name.ends_with_insensitive("jl_stenv_t") ||
                   Name.ends_with_insensitive("jl_varbinding_t") ||
                   Name.ends_with_insensitive("set_world") ||
                   Name.ends_with_insensitive("jl_codectx_t")) {
                 return true;
               }
               return false;
             },
             QT);
}

bool GCChecker::isGCTracked(const Expr *E) {
  while (1) {
    if (isGCTrackedType(E->getType()))
      return true;
    if (auto ICE = dyn_cast<ImplicitCastExpr>(E))
      E = ICE->getSubExpr();
    else if (auto CE = dyn_cast<CastExpr>(E))
      E = CE->getSubExpr();
    else
      return false;
  }
}

bool GCChecker::isGloballyRootedType(QualType QT) const {
  return isJuliaType(
      [](StringRef Name) { return Name.ends_with("jl_sym_t"); }, QT);
}

bool GCChecker::isSafepoint(const CallEvent &Call, CheckerContext &C) const {
  bool isCalleeSafepoint = true;
  if (Call.isInSystemHeader()) {
    // defined by -isystem per
    // https://clang.llvm.org/docs/UsersManual.html#controlling-diagnostics-in-system-headers
    isCalleeSafepoint = false;
  } else {
    const clang::Decl *Decl = Call.getDecl(); // we might not have a simple call, or we might have an SVal
    const clang::Expr *Callee = nullptr;
    if (auto CE = dyn_cast_or_null<CallExpr>(Call.getOriginExpr())) {
      Callee = CE->getCallee();
      if (Decl == nullptr)
          Decl = CE->getCalleeDecl(); // ignores dyn_cast<FunctionDecl>, so it could also be a MemberDecl, etc.
    }
    const DeclContext *DC = Decl ? Decl->getDeclContext() : nullptr;
    while (DC) {
      // Anything in llvm or std is not a safepoint
      if (const NamespaceDecl *NDC = dyn_cast<NamespaceDecl>(DC))
        if (NDC->getName() == "llvm" || NDC->getName() == "std")
          return false;
      DC = DC->getParent();
    }
    const FunctionDecl *FD = Decl ? Decl->getAsFunction() : nullptr;
    if (!Decl || !FD) {
      if (Callee == nullptr) {
        isCalleeSafepoint = true;
      } else if (const ElaboratedType *ET = dyn_cast<ElaboratedType>(Callee->getType())){
        if (const TypedefType *TDT = dyn_cast<TypedefType>(ET->getNamedType())) {
          isCalleeSafepoint =
              !declHasAnnotation(TDT->getDecl(), "julia_not_safepoint");
        }
      } else if (const CXXPseudoDestructorExpr *PDE =
                     dyn_cast<CXXPseudoDestructorExpr>(Callee)) {
        // A pseudo-destructor is an expression that looks like a member
        // access to a destructor of a scalar type. A pseudo-destructor
        // expression has no run-time semantics beyond evaluating the base
        // expression (which would have it's own CallEvent, if applicable).
        isCalleeSafepoint = false;
      }
    } else if (FD) {
      if (FD->getBuiltinID() != 0 || FD->isTrivial())
        isCalleeSafepoint = false;
      else if (FD->getDeclName().isIdentifier() &&
               (FD->getName().starts_with("uv_") ||
                FD->getName().starts_with("unw_") ||
                FD->getName().starts_with("_U")) &&
               FD->getName() != "uv_run")
        isCalleeSafepoint = false;
      else
        isCalleeSafepoint = !isFDAnnotatedNotSafepoint(FD, getSM(C));
    }
  }
  return isCalleeSafepoint;
}

bool GCChecker::processPotentialSafepoint(const CallEvent &Call,
                                          CheckerContext &C,
                                          ProgramStateRef &State) const {
  if (!isSafepoint(Call, C))
    return false;
  bool DidChange = false;
  if (!gcEnabledHere(C))
    return false;
  const Decl *D = Call.getDecl();
  const FunctionDecl *FD = D ? D->getAsFunction() : nullptr;
  SymbolRef SpeciallyRootedSymbol = nullptr;
  if (FD) {
    for (unsigned i = 0; i < FD->getNumParams(); ++i) {
      QualType ParmType = FD->getParamDecl(i)->getType();
      if (declHasAnnotation(FD->getParamDecl(i), "julia_temporarily_roots")) {
        if (ParmType->isPointerType() &&
            ParmType->getPointeeType()->isPointerType() &&
            isGCTrackedType(ParmType->getPointeeType())) {
          // This is probably an out parameter. Find the value it refers to now.
          SVal Loaded =
              State->getSVal(*(Call.getArgSVal(i).getAs<Loc>()));
          SpeciallyRootedSymbol = Loaded.getAsSymbol();
          continue;
        }
        SVal Test = Call.getArgSVal(i);
        // Walk backwards to find the symbol that we're tracking for this
        // value
        const MemRegion *Region = Test.getAsRegion();
        SpeciallyRootedSymbol =
            walkToRoot([&](SymbolRef Sym,
                           const ValueState *OldVState) { return !OldVState; },
                       State, Region);
        break;
      }
    }
  }

  // Don't free the return value
  SymbolRef RetSym = Call.getReturnValue().getAsSymbol();

  // Symbolically free all unrooted values.
  GCValueMapTy AMap = State->get<GCValueMap>();
  for (auto I = AMap.begin(), E = AMap.end(); I != E; ++I) {
    if (I.getData().isJustAllocated()) {
      if (SpeciallyRootedSymbol == I.getKey())
        continue;
      if (RetSym == I.getKey())
        continue;
      State = State->set<GCValueMap>(I.getKey(), ValueState::getFreed());
      DidChange = true;
    }
  }
  return DidChange;
}

const GCChecker::ValueState *
GCChecker::getValStateForRegion(ASTContext &AstC, const ProgramStateRef &State,
                                const MemRegion *Region, bool Debug) {
  if (!Region)
    return nullptr;
  SymbolRef Sym = walkToRoot(
      [&](SymbolRef Sym, const ValueState *OldVState) {
        return !OldVState || !OldVState->isRooted();
      },
      State, Region);
  if (!Sym)
    return nullptr;
  return State->get<GCValueMap>(Sym);
}

bool GCChecker::processArgumentRooting(const CallEvent &Call, CheckerContext &C,
                                       ProgramStateRef &State) const {
  auto *Decl = Call.getDecl();
  const FunctionDecl *FD = Decl ? Decl->getAsFunction() : nullptr;
  if (!FD)
    return false;
  const MemRegion *RootingRegion = nullptr;
  SymbolRef RootedSymbol = nullptr;
  for (unsigned i = 0; i < FD->getNumParams(); ++i) {
    if (declHasAnnotation(FD->getParamDecl(i), "julia_rooting_argument")) {
      RootingRegion = Call.getArgSVal(i).getAsRegion();
    } else if (declHasAnnotation(FD->getParamDecl(i),
                                 "julia_rooted_argument")) {
      RootedSymbol = Call.getArgSVal(i).getAsSymbol();
    }
  }
  if (!RootingRegion || !RootedSymbol)
    return false;
  const ValueState *OldVState =
      getValStateForRegion(C.getASTContext(), State, RootingRegion);
  if (!OldVState)
    return false;
  State = State->set<GCValueMap>(RootedSymbol, *OldVState);
  return true;
}

bool GCChecker::processAllocationOfResult(const CallEvent &Call,
                                          CheckerContext &C,
                                          ProgramStateRef &State) const {
  QualType QT = Call.getResultType();
  if (!isGCTrackedType(QT))
    return false;
  if (!Call.getOriginExpr()) {
    return false;
  }
  SymbolRef Sym = Call.getReturnValue().getAsSymbol();
  if (!Sym) {
    SVal S = C.getSValBuilder().conjureSymbolVal(
        Call.getOriginExpr(), C.getLocationContext(), QT, C.blockCount());
    State = State->BindExpr(Call.getOriginExpr(), C.getLocationContext(), S);
    Sym = S.getAsSymbol();
  }
  if (isGloballyRootedType(QT))
    State = State->set<GCValueMap>(Sym, ValueState::getRooted(nullptr, -1));
  else {
    const ValueState *ValS = State->get<GCValueMap>(Sym);
    ValueState NewVState = ValS ? *ValS : ValueState::getAllocated();
    auto *Decl = Call.getDecl();
    const FunctionDecl *FD = Decl ? Decl->getAsFunction() : nullptr;
    if (FD) {
      if (declHasAnnotation(FD, "julia_globally_rooted")) {
        NewVState = ValueState::getRooted(nullptr, -1);
      } else {
        // Special case for jl_box_ functions which have value-dependent
        // global roots.
        StringRef FDName =
            FD->getDeclName().isIdentifier() ? FD->getName() : "";
        if (FDName.starts_with("jl_box_") || FDName.starts_with("ijl_box_")) {
          SVal Arg = Call.getArgSVal(0);
          if (auto CI = Arg.getAs<nonloc::ConcreteInt>()) {
            const llvm::APSInt &Value = CI->getValue();
            bool GloballyRooted = false;
            const int64_t NBOX_C = 1024;
            if (FDName.starts_with("jl_box_u") || FDName.starts_with("ijl_box_u")) {
              if (Value < NBOX_C) {
                GloballyRooted = true;
              }
            } else {
              if (-NBOX_C / 2 < Value && Value < (NBOX_C - NBOX_C / 2)) {
                GloballyRooted = true;
              }
            }
            if (GloballyRooted) {
              NewVState = ValueState::getRooted(nullptr, -1);
            }
          }
        } else {
          for (unsigned i = 0; i < FD->getNumParams(); ++i) {
            if (declHasAnnotation(FD->getParamDecl(i),
                                  "julia_propagates_root")) {
              SVal Test = Call.getArgSVal(i);
              // Walk backwards to find the region that roots this value
              const MemRegion *Region = Test.getAsRegion();
              const ValueState *OldVState =
                  getValStateForRegion(C.getASTContext(), State, Region);
              if (OldVState)
                NewVState = *OldVState;
              break;
            }
          }
        }
      }
    }
    State = State->set<GCValueMap>(Sym, NewVState);
  }
  return true;
}

void GCChecker::checkPostCall(const CallEvent &Call, CheckerContext &C) const {
  ProgramStateRef State = C.getState();
  bool didChange = processArgumentRooting(Call, C, State);
  didChange |= processPotentialSafepoint(Call, C, State);
  didChange |= processAllocationOfResult(Call, C, State);
  if (didChange)
    C.addTransition(State);
}

// Implicitly root values that were casted to globally rooted values
void GCChecker::checkPostStmt(const CStyleCastExpr *CE,
                              CheckerContext &C) const {
  if (!isGloballyRootedType(CE->getTypeAsWritten()))
    return;
  SymbolRef Sym = C.getSVal(CE).getAsSymbol();
  if (!Sym)
    return;
  C.addTransition(
      C.getState()->set<GCValueMap>(Sym, ValueState::getRooted(nullptr, -1)));
}

SymbolRef GCChecker::getSymbolForResult(const Expr *Result,
                                        const ValueState *OldValS,
                                        ProgramStateRef &State,
                                        CheckerContext &C) const {
  QualType QT = Result->getType();
  if (!QT->isPointerType() || QT->getPointeeType()->isVoidType())
    return nullptr;
  auto ValLoc = State->getSVal(Result, C.getLocationContext()).getAs<Loc>();
  if (!ValLoc) {
    return nullptr;
  }
  SVal Loaded = State->getSVal(*ValLoc);
  if (Loaded.isUnknown() || !Loaded.getAsSymbol()) {
    if (OldValS || GCChecker::isGCTracked(Result)) {
      Loaded = C.getSValBuilder().conjureSymbolVal(
          nullptr, Result, C.getLocationContext(), Result->getType(),
          C.blockCount());
      State = State->bindLoc(*ValLoc, Loaded, C.getLocationContext());
      // State = State->BindExpr(Result, C.getLocationContext(),
      // State->getSVal(*ValLoc));
    }
  }
  return Loaded.getAsSymbol();
}

void GCChecker::checkDerivingExpr(const Expr *Result, const Expr *Parent,
                                  bool ParentIsLoc, CheckerContext &C) const {
  if (auto PE = dyn_cast<ParenExpr>(Parent)) {
    Parent = PE->getSubExpr();
  }
  if (auto UO = dyn_cast<UnaryOperator>(Parent)) {
    if (UO->getOpcode() == UO_AddrOf) {
      Parent = UO->getSubExpr();
    }
  }
  bool ResultTracked = true;
  ProgramStateRef State = C.getState();
  if (isGloballyRootedType(Result->getType())) {
    SymbolRef NewSym = getSymbolForResult(Result, nullptr, State, C);
    if (!NewSym) {
      return;
    }
    const ValueState *NewValS = State->get<GCValueMap>(NewSym);
    if (NewValS && NewValS->isRooted() && NewValS->RootDepth == -1) {
      return;
    }
    C.addTransition(
        State->set<GCValueMap>(NewSym, ValueState::getRooted(nullptr, -1)));
    return;
  }
  if (!isGCTracked(Result)) {
    // TODO: We may want to refine this. This is to track pointers through the
    // array list in jl_module_t.
    bool ParentIsModule = isJuliaType(
        [](StringRef Name) { return Name.ends_with("jl_module_t"); },
        Parent->getType());
    bool ResultIsArrayList = isJuliaType(
        [](StringRef Name) { return Name.ends_with("arraylist_t"); },
        Result->getType());
    if (!(ParentIsModule && ResultIsArrayList) && isGCTracked(Parent)) {
      ResultTracked = false;
    }
  }
  // This is the pointer
  auto ResultVal = C.getSVal(Result);
  if (ResultVal.isUnknown()) {
    if (!Result->getType()->isPointerType()) {
      return;
    }
    ResultVal = C.getSValBuilder().conjureSymbolVal(
        Result, C.getLocationContext(), Result->getType(),
        C.blockCount());
    State = State->BindExpr(Result, C.getLocationContext(), ResultVal);
  }
  auto ValLoc = ResultVal.getAs<Loc>();
  if (!ValLoc)
    return;
  SVal ParentVal = C.getSVal(Parent);
  SymbolRef OldSym = ParentVal.getAsSymbol(true);
  const MemRegion *Region = C.getSVal(Parent).getAsRegion();
  const ValueState *OldValS = OldSym ? State->get<GCValueMap>(OldSym) : nullptr;
  SymbolRef NewSym = getSymbolForResult(Result, OldValS, State, C);
  if (!NewSym) {
    return;
  }
  // NewSym might already have a better root
  const ValueState *NewValS = State->get<GCValueMap>(NewSym);
  if (Region) {
    const VarRegion *VR = Region->getAs<VarRegion>();
    bool inheritedState = false;
    ValueState Updated = ValueState::getRooted(Region, -1);
    if (VR && isa<ParmVarDecl>(VR->getDecl())) {
      // This works around us not being able to track symbols for struct/union
      // parameters very well.
      const auto *FD =
          dyn_cast<FunctionDecl>(C.getLocationContext()->getDecl());
      if (FD) {
        inheritedState = true;
        bool isFunctionSafepoint = !isFDAnnotatedNotSafepoint(FD, getSM(C));
        Updated =
            ValueState::getForArgument(FD, cast<ParmVarDecl>(VR->getDecl()), isFunctionSafepoint);
      }
    } else {
      VR = Helpers::walk_back_to_global_VR(Region);
      if (VR) {
        if (VR && rootRegionIfGlobal(VR, State, C)) {
          inheritedState = true;
        }
      }
    }
    if (inheritedState && ResultTracked) {
      C.addTransition(State->set<GCValueMap>(NewSym, Updated));
      return;
    }
  }
  if (NewValS && NewValS->isRooted()) {
    return;
  }
  if (!OldValS) {
    // This way we'll get better diagnostics
    if (isGCTracked(Result)) {
      C.addTransition(
          State->set<GCValueMap>(NewSym, ValueState::getUntracked()));
    }
    return;
  }
  if (OldValS->isPotentiallyFreed()) {
    report_value_error(C, OldSym,
                       "Creating derivative of value that may have been GCed");
  } else if (ResultTracked) {
    C.addTransition(State->set<GCValueMap>(NewSym, *OldValS));
    return;
  }
}

// Propagate rootedness through subscript
void GCChecker::checkPostStmt(const ArraySubscriptExpr *ASE,
                              CheckerContext &C) const {
  // Could be a root array, in which case this should be considered rooted
  // by that array.
  const MemRegion *Region = C.getSVal(ASE->getLHS()).getAsRegion();
  ProgramStateRef State = C.getState();
  if (Region && Region->getAs<ElementRegion>() && isGCTracked(ASE)) {
    const RootState *RS =
        State->get<GCRootMap>(Region->getAs<ElementRegion>()->getSuperRegion());
    if (RS) {
      ValueState ValS = ValueState::getRooted(Region, State->get<GCDepth>());
      SymbolRef NewSym = getSymbolForResult(ASE, &ValS, State, C);
      if (!NewSym) {
        return;
      }
      const ValueState *ExistingValS = State->get<GCValueMap>(NewSym);
      if (ExistingValS && ExistingValS->isRooted() &&
          ExistingValS->RootDepth < ValS.RootDepth)
        return;
      C.addTransition(State->set<GCValueMap>(NewSym, ValS));
      return;
    }
  }
  checkDerivingExpr(ASE, ASE->getLHS(), true, C);
}

void GCChecker::checkPostStmt(const MemberExpr *ME, CheckerContext &C) const {
  // It is possible for the member itself to be gcrooted, so check that first
  const MemRegion *Region = C.getSVal(ME).getAsRegion();
  ProgramStateRef State = C.getState();
  if (Region && isGCTracked(ME)) {
    if (const RootState *RS = State->get<GCRootMap>(Region)) {
      ValueState ValS = ValueState::getRooted(Region, RS->RootedAtDepth);
      SymbolRef NewSym = getSymbolForResult(ME, &ValS, State, C);
      if (!NewSym)
        return;
      const ValueState *ExistingValS = State->get<GCValueMap>(NewSym);
      if (ExistingValS && ExistingValS->isRooted() &&
          ExistingValS->RootDepth < ValS.RootDepth)
        return;
      C.addTransition(C.getState()->set<GCValueMap>(NewSym, ValS));
      return;
    }
  }
  if (!ME->getType()->isPointerType())
    return;
  clang::Expr *Base = ME->getBase();
  checkDerivingExpr(ME, Base, true, C);
}

void GCChecker::checkPostStmt(const UnaryOperator *UO,
                              CheckerContext &C) const {
  if (UO->getOpcode() == UO_Deref) {
    checkDerivingExpr(UO, UO->getSubExpr(), true, C);
  }
}

USED_FUNC void GCChecker::dumpState(const ProgramStateRef &State) {
  GCValueMapTy AMap = State->get<GCValueMap>();
  llvm::raw_ostream &Out = llvm::outs();
  Out << "State: "
      << "\n";
  for (auto I = AMap.begin(), E = AMap.end(); I != E; ++I) {
    I.getKey()->dumpToStream(Out);
  }
}

void GCChecker::checkPreCall(const CallEvent &Call, CheckerContext &C) const {
  if (!gcEnabledHere(C))
    return;
  unsigned NumArgs = Call.getNumArgs();
  ProgramStateRef State = C.getState();
  bool isCalleeSafepoint = isSafepoint(Call, C);
  auto *Decl = Call.getDecl();
  const FunctionDecl *FD = Decl ? Decl->getAsFunction() : nullptr;
  StringRef FDName =
      FD && FD->getDeclName().isIdentifier() ? FD->getName() : "";
  if (isMutexUnlock(FDName) || (FD && declHasAnnotation(FD, "julia_notsafepoint_leave"))) {
    const auto *LCtx = C.getLocationContext();
    const auto *FD = dyn_cast<FunctionDecl>(LCtx->getDecl());
    if (State->get<SafepointDisabledAt>() == getStackFrameHeight(C.getStackFrame()) &&
        !isFDAnnotatedNotSafepoint(FD, getSM(C))) {
      State = State->set<SafepointDisabledAt>((unsigned)-1);
      C.addTransition(State);
    }
  }
  if (!safepointEnabledHere(State) && isCalleeSafepoint) {
    // Suppress this warning if the function is noreturn.
    // We could separate out "not safepoint, except for noreturn functions",
    // but that seems like a lot of effort with little benefit.
    if (!FD || !FD->isNoReturn()) {
      report_error(
          [&](PathSensitiveBugReport *Report) {
            if (FD)
              Report->addNote(
                  "Tried to call method defined here",
                  PathDiagnosticLocation::create(FD, C.getSourceManager()));
            Report->addVisitor(make_unique<SafepointBugVisitor>());
          },
          C, ("Calling potential safepoint as " +
              Call.getKindAsString() + " from function annotated JL_NOTSAFEPOINT").str());
      return;
    }
  }
  if (FD && FD->getDeclName().isIdentifier() &&
      FD->getName() == "JL_GC_PROMISE_ROOTED")
    return;
  for (unsigned idx = 0; idx < NumArgs; ++idx) {
    SVal Arg = Call.getArgSVal(idx);
    SymbolRef Sym = Arg.getAsSymbol();
    // Hack to work around passing unions/structs by value.
    if (auto LCV = Arg.getAs<nonloc::LazyCompoundVal>()) {
      const MemRegion *R = LCV->getRegion();
      if (R) {
        if (const SubRegion *SR = R->getAs<SubRegion>()) {
          if (const SymbolicRegion *SSR =
                  SR->getSuperRegion()->getAs<SymbolicRegion>()) {
            Sym = SSR->getSymbol();
          }
        }
      }
    }
    if (!Sym)
      continue;
    auto *ValState = State->get<GCValueMap>(Sym);
    if (!ValState)
      continue;
    SourceRange range;
    if (const Expr *E = Call.getArgExpr(idx)) {
      range = E->getSourceRange();
      if (!isGCTracked(E))
        continue;
    }
    if (ValState->isPotentiallyFreed()) {
      report_value_error(C, Sym, "Argument value may have been GCed", range);
    }
    if (ValState->isRooted())
      continue;
    bool MaybeUnrooted = false;
    if (FD) {
      if (idx < FD->getNumParams()) {
        MaybeUnrooted =
            declHasAnnotation(FD->getParamDecl(idx), "julia_maybe_unrooted");
      }
    }
    if (!MaybeUnrooted && isCalleeSafepoint) {
      report_value_error(
          C, Sym,
          "Passing non-rooted value as argument to function that may GC",
          range);
    }
  }
}

bool GCChecker::evalCall(const CallEvent &Call, CheckerContext &C) const {
  // These checks should have no effect on the surrounding environment
  // (globals should not be invalidated, etc), hence the use of evalCall.
  const CallExpr *CE = dyn_cast<CallExpr>(Call.getOriginExpr());
  if (!CE)
    return false;
  unsigned CurrentDepth = C.getState()->get<GCDepth>();
  auto name = C.getCalleeName(CE);
  if (name == "JL_GC_POP") {
    if (CurrentDepth == 0) {
      report_error(C, "JL_GC_POP without corresponding push");
      return true;
    }
    CurrentDepth -= 1;
    // Go through all roots, see which ones are no longer with us.
    // The go through the values and unroot those for which those were our
    // roots.
    ProgramStateRef State = C.getState()->set<GCDepth>(CurrentDepth);
    GCRootMapTy AMap = State->get<GCRootMap>();
    SmallVector<const MemRegion *, 5> PoppedRoots;
    for (auto I = AMap.begin(), E = AMap.end(); I != E; ++I) {
      if (I.getData().shouldPopAtDepth(CurrentDepth)) {
        PoppedRoots.push_back(I.getKey());
        State = State->remove<GCRootMap>(I.getKey());
      }
    }
    GCValueMapTy VMap = State->get<GCValueMap>();
    for (const MemRegion *R : PoppedRoots) {
      for (auto I = VMap.begin(), E = VMap.end(); I != E; ++I) {
        if (I.getData().isRootedBy(R)) {
          State =
              State->set<GCValueMap>(I.getKey(), ValueState::getAllocated());
        }
      }
    }
    C.addTransition(State);
    return true;
  } else if (name == "JL_GC_PUSH1" || name == "JL_GC_PUSH2" ||
             name == "JL_GC_PUSH3" || name == "JL_GC_PUSH4" ||
             name == "JL_GC_PUSH5" || name == "JL_GC_PUSH6" ||
             name == "JL_GC_PUSH7" || name == "JL_GC_PUSH8" ||
             name == "JL_GC_PUSH9") {
    ProgramStateRef State = C.getState();
    // Transform slots to roots, transform values to rooted
    unsigned NumArgs = CE->getNumArgs();
    for (unsigned i = 0; i < NumArgs; ++i) {
      SVal V = C.getSVal(CE->getArg(i));
      auto MRV = V.getAs<loc::MemRegionVal>();
      if (!MRV) {
        report_error(C, "JL_GC_PUSH with something other than a local variable");
        return true;
      }
      const MemRegion *Region = MRV->getRegion();
      State = State->set<GCRootMap>(Region, RootState::getRoot(CurrentDepth));
      // Now for the value
      SVal Value = State->getSVal(Region);
      SymbolRef Sym = Value.getAsSymbol();
      if (!Sym)
        continue;
      const ValueState *ValState = State->get<GCValueMap>(Sym);
      if (!ValState)
        continue;
      if (ValState->isPotentiallyFreed())
        report_value_error(C, Sym,
                           "Trying to root value which may have been GCed");
      if (!ValState->isRooted()) {
        State = State->set<GCValueMap>(
            Sym, ValueState::getRooted(Region, CurrentDepth));
      }
    }
    CurrentDepth += 1;
    State = State->set<GCDepth>(CurrentDepth);
    C.addTransition(State);
    return true;
  } else if (name == "_JL_GC_PUSHARGS") {
    ProgramStateRef State = C.getState();
    SVal ArgArray = C.getSVal(CE->getArg(0));
    auto MRV = ArgArray.getAs<loc::MemRegionVal>();
    if (!MRV) {
      report_error(C, "JL_GC_PUSH with something other than an args array");
      return true;
    }
    const MemRegion *Region = MRV->getRegion()->StripCasts();
    State =
        State->set<GCRootMap>(Region, RootState::getRootArray(CurrentDepth));
    // The Argument array may also be used as a value, so make it rooted
    // SymbolRef ArgArraySym = ArgArray.getAsSymbol();
    // assert(ArgArraySym);
    // State = State->set<GCValueMap>(ArgArraySym, ValueState::getRooted(Region,
    // CurrentDepth));
    CurrentDepth += 1;
    State = State->set<GCDepth>(CurrentDepth);
    C.addTransition(State);
    return true;
  } else if (name == "JL_GC_PROMISE_ROOTED") {
    SVal Arg = C.getSVal(CE->getArg(0));
    SymbolRef Sym = Arg.getAsSymbol();
    if (!Sym) {
      report_error(C, "Can not understand this promise.");
      return true;
    }
    C.addTransition(
        C.getState()->set<GCValueMap>(Sym, ValueState::getRooted(nullptr, -1)));
    return true;
  } else if (name == "jl_gc_push_arraylist") {
    CurrentDepth += 1;
    ProgramStateRef State = C.getState()->set<GCDepth>(CurrentDepth);
    SVal ArrayList = C.getSVal(CE->getArg(1));
    // Try to find the items field
    FieldDecl *FD = NULL;
    RecordDecl *RD = dyn_cast_or_null<RecordDecl>(
        CE->getArg(1)->getType()->getPointeeType()->getAsTagDecl());
    if (RD) {
      for (FieldDecl *X : RD->fields()) {
        if (X->getName() == "items") {
          FD = X;
          break;
        }
      }
    }
    if (FD) {
      Loc ItemsLoc = *(State->getLValue(FD, ArrayList).getAs<Loc>());
      SVal Items = State->getSVal(ItemsLoc);
      if (Items.isUnknown()) {
        Items = C.getSValBuilder().conjureSymbolVal(
            CE, C.getLocationContext(), FD->getType(), C.blockCount());
        State = State->bindLoc(ItemsLoc, Items, C.getLocationContext());
      }
      assert(Items.getAsRegion());
      // The items list is now rooted
      State = State->set<GCRootMap>(Items.getAsRegion(),
                                    RootState::getRootArray(CurrentDepth));
    }
    C.addTransition(State);
    return true;
  } else if (name == "jl_ast_preserve") {
    // TODO: Maybe bind the rooting to the context. For now, the second
    //       argument gets unconditionally rooted
    ProgramStateRef State = C.getState();
    SymbolRef Sym = C.getSVal(CE->getArg(1)).getAsSymbol();
    if (!Sym)
      return true;
    C.addTransition(
        State->set<GCValueMap>(Sym, ValueState::getRooted(nullptr, -1)));
    return true;
  } else if (name == "jl_gc_enable" || name == "ijl_gc_enable") {
    ProgramStateRef State = C.getState();
    // Check for a literal argument
    SVal Arg = C.getSVal(CE->getArg(0));
    auto CI = Arg.getAs<nonloc::ConcreteInt>();
    bool EnabledAfter = true;
    if (CI) {
      const llvm::APSInt &Val = CI->getValue();
      EnabledAfter = Val != 0;
    } else {
      cast<SymbolConjured>(Arg.getAsSymbol())->getStmt()->dump();
    }
    bool EnabledNow = gcEnabledHere(State);
    if (!EnabledAfter) {
      State = State->set<GCDisabledAt>((unsigned)-2);
    } else {
      State = State->set<GCDisabledAt>((unsigned)-1);
    }
    // GC State is explicitly modeled, so let's make sure
    // the execution matches our model
    SVal Result = C.getSValBuilder().makeTruthVal(EnabledNow, CE->getType());
    C.addTransition(State->BindExpr(CE, C.getLocationContext(), Result));
    return true;
  }
  {
      auto *Decl = Call.getDecl();
      const FunctionDecl *FD = Decl ? Decl->getAsFunction() : nullptr;
      if (isMutexLock(name) || (FD && declHasAnnotation(FD, "julia_notsafepoint_enter"))) {
        ProgramStateRef State = C.getState();
        if (State->get<SafepointDisabledAt>() == (unsigned)-1) {
          C.addTransition(State->set<SafepointDisabledAt>(getStackFrameHeight(C.getStackFrame())));
          return true;
        }
      }
  }
  return false;
}

void GCChecker::checkBind(SVal LVal, SVal RVal, const clang::Stmt *S,
                          CheckerContext &C) const {
  auto State = C.getState();
  const MemRegion *R = LVal.getAsRegion();
  if (!R) {
    return;
  }
  bool shouldBeRootArray = false;
  const ElementRegion *ER = R->getAs<ElementRegion>();
  if (ER) {
    R = R->getBaseRegion()->StripCasts();
    shouldBeRootArray = true;
  }
  SymbolRef Sym = RVal.getAsSymbol();
  if (!Sym) {
    return;
  }
  const auto *RootState = State->get<GCRootMap>(R);
  if (!RootState) {
    const ValueState *ValSP = nullptr;
    ValueState ValS;
    if (rootRegionIfGlobal(R->getBaseRegion(), State, C, &ValS)) {
      ValSP = &ValS;
    } else {
      ValSP = getValStateForRegion(C.getASTContext(), State, R);
    }
    if (!ValSP || !ValSP->isRooted()) {
      return;
    }
    const auto *RValState = State->get<GCValueMap>(Sym);
    if (RValState && RValState->isRooted() &&
        RValState->RootDepth < ValSP->RootDepth)
      return;
    C.addTransition(State->set<GCValueMap>(Sym, *ValSP));
    return;
  }
  if (shouldBeRootArray && !RootState->isRootArray()) {
    report_error(
        C, "This assignment looks weird. Expected a root array on the LHS.");
    return;
  }
  const auto *RValState = State->get<GCValueMap>(Sym);
  if (!RValState) {
    if (rootRegionIfGlobal(Sym->getOriginRegion(), State, C)) {
      C.addTransition(State);
      return;
    }
    Sym->dump();
    if (auto *SC = dyn_cast<SymbolConjured>(Sym)) {
      SC->getStmt()->dump();
    }
    report_value_error(C, Sym,
                       "Saw assignment to root, but missed the allocation");
    return;
  }
  if (RValState->isPotentiallyFreed())
    report_value_error(C, Sym, "Trying to root value which may have been GCed");
  if (!RValState->isRooted() ||
      RValState->RootDepth > RootState->RootedAtDepth) {
    C.addTransition(State->set<GCValueMap>(
        Sym, ValueState::getRooted(R, RootState->RootedAtDepth)));
  }
}

bool GCChecker::rootRegionIfGlobal(const MemRegion *R, ProgramStateRef &State,
                                   CheckerContext &C, ValueState *ValS) const {
  if (!R)
    return false;
  const VarRegion *VR = R->getAs<VarRegion>();
  if (!VR)
    return false;
  const VarDecl *VD = VR->getDecl();
  assert(VD);
  if (!VD->hasGlobalStorage())
    return false;
  if (!isGCTrackedType(VD->getType()))
    return false;
  bool isGlobalRoot = false;
  if (declHasAnnotation(VD, "julia_globally_rooted") ||
      isGloballyRootedType(VD->getType())) {
    State = State->set<GCRootMap>(R, RootState::getRoot(-1));
    isGlobalRoot = true;
  }
  SVal TheVal = State->getSVal(R);
  SymbolRef Sym = TheVal.getAsSymbol();
  ValueState TheValS(isGlobalRoot ? ValueState::getRooted(R, -1)
                                  : ValueState::getAllocated());
  if (ValS)
    *ValS = TheValS;
  if (Sym) {
    const ValueState *GVState = C.getState()->get<GCValueMap>(Sym);
    if (!GVState)
      State = State->set<GCValueMap>(Sym, TheValS);
  }
  return true;
}

void GCChecker::checkLocation(SVal SLoc, bool IsLoad, const Stmt *S,
                              CheckerContext &C) const {
  ProgramStateRef State = C.getState();
  bool DidChange = false;
  const RootState *RS = nullptr;
  // Loading from a root produces a rooted symbol. TODO: Can we do something
  // better than this.
  if (IsLoad && (RS = State->get<GCRootMap>(SLoc.getAsRegion()))) {
    SymbolRef LoadedSym =
        State->getSVal(*SLoc.getAs<Loc>()).getAsSymbol();
    if (LoadedSym) {
      const ValueState *ValS = State->get<GCValueMap>(LoadedSym);
      if (!ValS || !ValS->isRooted() || ValS->RootDepth > RS->RootedAtDepth) {
        DidChange = true;
        State = State->set<GCValueMap>(
            LoadedSym,
            ValueState::getRooted(SLoc.getAsRegion(), RS->RootedAtDepth));
      }
    }
  }
  // If it's just the symbol by itself, let it be. We allow dead pointer to be
  // passed around, so long as they're not accessed. However, we do want to
  // start tracking any globals that may have been accessed.
  if (rootRegionIfGlobal(SLoc.getAsRegion(), State, C)) {
    C.addTransition(State);
    return;
  }
  SymbolRef SymByItself = SLoc.getAsSymbol(false);
  if (SymByItself) {
    DidChange &&C.addTransition(State);
    return;
  }
  // This will walk backwards until it finds the base symbol
  SymbolRef Sym = SLoc.getAsSymbol(true);
  if (!Sym) {
    DidChange &&C.addTransition(State);
    return;
  }
  const ValueState *VState = State->get<GCValueMap>(Sym);
  if (!VState) {
    DidChange &&C.addTransition(State);
    return;
  }
  if (VState->isPotentiallyFreed()) {
    report_value_error(C, Sym,
                       "Trying to access value which may have been GCed");
  }
  DidChange &&C.addTransition(State);
}

namespace clang {
namespace ento {
void registerGCChecker(CheckerManager &mgr) {
  mgr.registerChecker<GCChecker>();
}
} // namespace ento
} // namespace clang

#ifdef CLANG_PLUGIN
extern "C" const char clang_analyzerAPIVersionString[] =
    CLANG_ANALYZER_API_VERSION_STRING;
extern "C" void clang_registerCheckers(CheckerRegistry &registry) {
  registry.addChecker<GCChecker>(
      "julia.GCChecker", "Validates julia gc invariants",
      "https://docs.julialang.org/en/v1/devdocs/gc-sa/"
  );
}
#endif
