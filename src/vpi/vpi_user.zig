//! vpi_user.h's integer macros, from the Zig side: every object type,
//! relationship, property, value format, flag, callback reason and control
//! operation a routine answers or takes, one constant each.
//! Cites: IEEE 1364-2005 Annex G (the numbering §12.2 and §12.31 defer to);
//! the VAMS-2023 §11.6/§12 names it does not number are VerA's, shared with
//! src/vpi/vpi_user.h and tests/conformance/tests/verilog-ams/ch12_vpi_routines/p03_vpi_analog.h.
//! Nothing shares a source of truth with the header: tests/unit.zig's
//! `vpi_tests` reads the header and checks every constant here against it.
//!
//! Contents:
//! - `pub const vpiExpStrVal: c_int`
//! - `pub const vpiScaledRealTime: c_int`
//! - `pub const vpiSimTime: c_int`
//! - `pub const vpiSuppressTime: c_int`
//! - `pub const vpiAnalogTime: c_int`
//! - `pub const cbValueChange: c_int`
//! - `pub const cbStmt: c_int`
//! - `pub const cbForce: c_int`
//! - `pub const cbRelease: c_int`
//! - `pub const cbAtStartOfSimTime: c_int`
//! - `pub const cbReadWriteSynch: c_int`
//! - `pub const cbReadOnlySynch: c_int`
//! - `pub const cbNextSimTime: c_int`
//! - `pub const cbAfterDelay: c_int`
//! - `pub const cbEndOfCompile: c_int`
//! - `pub const cbStartOfSimulation: c_int`
//! - `pub const cbEndOfSimulation: c_int`
//! - `pub const cbError: c_int`
//! - `pub const cbTchkViolation: c_int`
//! - `pub const cbStartOfReset: c_int`
//! - `pub const cbEndOfReset: c_int`
//! - `pub const cbInteractiveScopeChange: c_int`
//! - `pub const cbAssign: c_int`
//! - `pub const cbDeassign: c_int`
//! - `pub const cbDisable: c_int`
//! - `pub const cbPLIError: c_int`
//! - `pub const acbInitialStep: c_int`
//! - `pub const acbFinalStep: c_int`
//! - `pub const acbAbsTime: c_int`
//! - `pub const acbElapsedTime: c_int`
//! - `pub const acbConvergenceTest: c_int`
//! - `pub const acbAcceptedPoint: c_int`
//! - `pub const vpiCallback: c_int`
//! - `pub const vpiAlways: c_int`
//! - `pub const vpiAssignStmt: c_int`
//! - `pub const vpiAssignment: c_int`
//! - `pub const vpiBegin: c_int`
//! - `pub const vpiCase: c_int`
//! - `pub const vpiCaseItem: c_int`
//! - `pub const vpiContAssign: c_int`
//! - `pub const vpiDeassign: c_int`
//! - `pub const vpiDelayControl: c_int`
//! - `pub const vpiDisable: c_int`
//! - `pub const vpiEventControl: c_int`
//! - `pub const vpiEventStmt: c_int`
//! - `pub const vpiFor: c_int`
//! - `pub const vpiForce: c_int`
//! - `pub const vpiForever: c_int`
//! - `pub const vpiFork: c_int`
//! - `pub const vpiFuncCall: c_int`
//! - `pub const vpiFunction: c_int`
//! - `pub const vpiIf: c_int`
//! - `pub const vpiIfElse: c_int`
//! - `pub const vpiInitial: c_int`
//! - `pub const vpiAttribute: c_int`
//! - `pub const vpiDefAttribute: c_int`
//! - `pub const vpiIODecl: c_int`
//! - `pub const vpiNamedBegin: c_int`
//! - `pub const vpiNamedEvent: c_int`
//! - `pub const vpiNamedEventArray: c_int`
//! - `pub const vpiNamedFork: c_int`
//! - `pub const vpiNetBit: c_int`
//! - `pub const vpiNullStmt: c_int`
//! - `pub const vpiOperation: c_int`
//! - `pub const vpiPartSelect: c_int`
//! - `pub const vpiIndexedPartSelect: c_int`
//! - `pub const vpiRegBit: c_int`
//! - `pub const vpiRelease: c_int`
//! - `pub const vpiRepeat: c_int`
//! - `pub const vpiRepeatControl: c_int`
//! - `pub const vpiSysFuncCall: c_int`
//! - `pub const vpiSysTaskCall: c_int`
//! - `pub const vpiTask: c_int`
//! - `pub const vpiTaskCall: c_int`
//! - `pub const vpiWait: c_int`
//! - `pub const vpiWhile: c_int`
//! - `pub const vpiParamAssign: c_int`
//! - `pub const vpiGate: c_int`
//! - `pub const vpiPrimTerm: c_int`
//! - `pub const vpiTableEntry: c_int`
//! - `pub const vpiUdp: c_int`
//! - `pub const vpiUdpDefn: c_int`
//! - `pub const vpiPrimitive: c_int`
//! - `pub const vpiPrimType: c_int`
//! - `pub const vpiTermIndex: c_int`
//! - `pub const vpiSwitch: c_int`
//! - `pub const vpiPullupPrim: c_int`
//! - `pub const vpiPulldownPrim: c_int`
//! - `pub const vpiStrength0: c_int`
//! - `pub const vpiStrength1: c_int`
//! - `pub const vpiSeqPrim: c_int`
//! - `pub const vpiCombPrim: c_int`
//! - `pub const vpiCondition: c_int`
//! - `pub const vpiDelay: c_int`
//! - `pub const vpiElseStmt: c_int`
//! - `pub const vpiForIncStmt: c_int`
//! - `pub const vpiForInitStmt: c_int`
//! - `pub const vpiLhs: c_int`
//! - `pub const vpiHighConn: c_int`
//! - `pub const vpiLowConn: c_int`
//! - `pub const vpiLeftRange: c_int`
//! - `pub const vpiRhs: c_int`
//! - `pub const vpiArgument: c_int`
//! - `pub const vpiOperand: c_int`
//! - `pub const vpiProcess: c_int`
//! - `pub const vpiExpr: c_int`
//! - `pub const vpiBaseExpr: c_int`
//! - `pub const vpiWidthExpr: c_int`
//! - `pub const vpiDriver: c_int`
//! - `pub const vpiLoad: c_int`
//! - `pub const vpiLocalDriver: c_int`
//! - `pub const vpiLocalLoad: c_int`
//! - `pub const vpiModPath: c_int`
//! - `pub const vpiPathTerm: c_int`
//! - `pub const vpiTchk: c_int`
//! - `pub const vpiTchkTerm: c_int`
//! - `pub const vpiTchkDataTerm: c_int`
//! - `pub const vpiTchkNotifier: c_int`
//! - `pub const vpiTchkRefTerm: c_int`
//! - `pub const vpiModPathIn: c_int`
//! - `pub const vpiModPathOut: c_int`
//! - `pub const vpiModDataPathIn: c_int`
//! - `pub const vpiModPathHasIfNone: c_int`
//! - `pub const vpiEdge: c_int`
//! - `pub const vpiPathType: c_int`
//! - `pub const vpiPolarity: c_int`
//! - `pub const vpiDataPolarity: c_int`
//! - `pub const vpiTchkType: c_int`
//! - `pub const vpiPathFull: c_int`
//! - `pub const vpiPathParallel: c_int`
//! - `pub const vpiPositive: c_int`
//! - `pub const vpiNegative: c_int`
//! - `pub const vpiUnknown: c_int`
//! - `pub const vpiNoEdge: c_int`
//! - `pub const vpiPosedge: c_int`
//! - `pub const vpiNegedge: c_int`
//! - `pub const vpiAnyEdge: c_int`
//! - `pub const vpiStmt: c_int`
//! - `pub const vpiRightRange: c_int`
//! - `pub const vpiRange: c_int`
//! - `pub const vpiGenScopeArray: c_int`
//! - `pub const vpiGenScope: c_int`
//! - `pub const vpiImplicitDecl: c_int`
//! - `pub const vpiOpType: c_int`
//! - `pub const vpiBlocking: c_int`
//! - `pub const vpiCaseType: c_int`
//! - `pub const vpiNetDeclAssign: c_int`
//! - `pub const vpiFuncType: c_int`
//! - `pub const vpiIntFunc: c_int`
//! - `pub const vpiRealFunc: c_int`
//! - `pub const vpiTimeFunc: c_int`
//! - `pub const vpiSizedFunc: c_int`
//! - `pub const vpiSizedSignedFunc: c_int`
//! - `pub const vpiConnByName: c_int`
//! - `pub const vpiIndexedPartSelectType: c_int`
//! - `pub const vpiPosIndexed: c_int`
//! - `pub const vpiNegIndexed: c_int`
//! - `pub const vpiBinaryConst: c_int`
//! - `pub const vpiOctConst: c_int`
//! - `pub const vpiHexConst: c_int`
//! - `pub const vpiCaseExact: c_int`
//! - `pub const vpiCaseX: c_int`
//! - `pub const vpiCaseZ: c_int`
//! - `pub const vpiMinusOp: c_int`
//! - `pub const vpiPlusOp: c_int`
//! - `pub const vpiNotOp: c_int`
//! - `pub const vpiBitNegOp: c_int`
//! - `pub const vpiUnaryAndOp: c_int`
//! - `pub const vpiUnaryNandOp: c_int`
//! - `pub const vpiUnaryOrOp: c_int`
//! - `pub const vpiUnaryNorOp: c_int`
//! - `pub const vpiUnaryXorOp: c_int`
//! - `pub const vpiUnaryXNorOp: c_int`
//! - `pub const vpiSubOp: c_int`
//! - `pub const vpiDivOp: c_int`
//! - `pub const vpiModOp: c_int`
//! - `pub const vpiEqOp: c_int`
//! - `pub const vpiNeqOp: c_int`
//! - `pub const vpiCaseEqOp: c_int`
//! - `pub const vpiCaseNeqOp: c_int`
//! - `pub const vpiGtOp: c_int`
//! - `pub const vpiGeOp: c_int`
//! - `pub const vpiLtOp: c_int`
//! - `pub const vpiLeOp: c_int`
//! - `pub const vpiLShiftOp: c_int`
//! - `pub const vpiRShiftOp: c_int`
//! - `pub const vpiAddOp: c_int`
//! - `pub const vpiMultOp: c_int`
//! - `pub const vpiLogAndOp: c_int`
//! - `pub const vpiLogOrOp: c_int`
//! - `pub const vpiBitAndOp: c_int`
//! - `pub const vpiBitOrOp: c_int`
//! - `pub const vpiBitXorOp: c_int`
//! - `pub const vpiBitXNorOp: c_int`
//! - `pub const vpiConditionOp: c_int`
//! - `pub const vpiConcatOp: c_int`
//! - `pub const vpiMultiConcatOp: c_int`
//! - `pub const vpiEventOrOp: c_int`
//! - `pub const vpiListOp: c_int`
//! - `pub const vpiPosedgeOp: c_int`
//! - `pub const vpiNegedgeOp: c_int`
//! - `pub const vpiArithLShiftOp: c_int`
//! - `pub const vpiArithRShiftOp: c_int`
//! - `pub const vpiPowerOp: c_int`
//! - `pub const vpiAnalog: c_int`
//! - `pub const vpiContrib: c_int`
//! - `pub const vpiDirect: c_int`
//! - `pub const vpiAccessFunc: c_int`
//! - `pub const vpiStartTime: c_int`
//! - `pub const vpiEndTime: c_int`
//! - `pub const vpiTransientMaxStep: c_int`
//! - `pub const vpiStartFrequency: c_int`
//! - `pub const vpiEndFrequency: c_int`
//! - `pub const vpiConstant: c_int`
//! - `pub const vpiIntegerVar: c_int`
//! - `pub const vpiIterator: c_int`
//! - `pub const vpiMemory: c_int`
//! - `pub const vpiMemoryWord: c_int`
//! - `pub const vpiRealVar: c_int`
//! - `pub const vpiVarSelect: c_int`
//! - `pub const vpiModuleArray: c_int`
//! - `pub const vpiRegArray: c_int`
//! - `pub const vpiTimeVar: c_int`
//! - `pub const vpiNetArray: c_int`
//! - `pub const vpiVariables: c_int`
//! - `pub const vpiAutomatic: c_int`
//! - `pub const vpiQuantity: c_int`
//! - `pub const vpiBranch: c_int`
//! - `pub const vpiPotential: c_int`
//! - `pub const vpiFlow: c_int`
//! - `pub const vpiPosNode: c_int`
//! - `pub const vpiNegNode: c_int`
//! - `pub const vpiNode: c_int`
//! - `pub const vpiDiscipline: c_int`
//! - `pub const vpiNature: c_int`
//! - `pub const vpiFlowNature: c_int`
//! - `pub const vpiPotentialNature: c_int`
//! - `pub const vpiChild: c_int`
//! - `pub const vpiArray: c_int`
//! - `pub const vpiIsMemory: c_int`
//! - `pub const vpiIndex: c_int`
//! - `pub const vpiParent: c_int`
//! - `pub const vpiDecConst: c_int`
//! - `pub const vpiModule: c_int`
//! - `pub const vpiNet: c_int`
//! - `pub const vpiParameter: c_int`
//! - `pub const vpiPort: c_int`
//! - `pub const vpiReg: c_int`
//! - `pub const vpiScope: c_int`
//! - `pub const vpiInternalScope: c_int`
//! - `pub const vpiBit: c_int`
//! - `pub const vpiUse: c_int`
//! - `pub const vpiIteratorType: c_int`
//! - `pub const vpiActiveTimeFormat: c_int`
//! - `pub const vpiUndefined: c_int`
//! - `pub const vpiType: c_int`
//! - `pub const vpiName: c_int`
//! - `pub const vpiFullName: c_int`
//! - `pub const vpiSize: c_int`
//! - `pub const vpiTopModule: c_int`
//! - `pub const vpiFile: c_int`
//! - `pub const vpiLineNo: c_int`
//! - `pub const vpiNetType: c_int`
//! - `pub const vpiProtected: c_int`
//! - `pub const vpiTimeUnit: c_int`
//! - `pub const vpiTimePrecision: c_int`
//! - `pub const vpiDefName: c_int`
//! - `pub const vpiCell: c_int`
//! - `pub const vpiConfig: c_int`
//! - `pub const vpiLibrary: c_int`
//! - `pub const vpiScalar: c_int`
//! - `pub const vpiVector: c_int`
//! - `pub const vpiDirection: c_int`
//! - `pub const vpiPortIndex: c_int`
//! - `pub const vpiConstType: c_int`
//! - `pub const vpiSigned: c_int`
//! - `pub const vpiLocalParam: c_int`
//! - `pub const vpiDecompile: c_int`
//! - `pub const vpiInput: c_int`
//! - `pub const vpiOutput: c_int`
//! - `pub const vpiInout: c_int`
//! - `pub const vpiMixedIO: c_int`
//! - `pub const vpiNoDirection: c_int`
//! - `pub const vpiRealConst: c_int`
//! - `pub const vpiStringConst: c_int`
//! - `pub const vpiIntConst: c_int`
//! - `pub const vpiCompile: c_int`
//! - `pub const vpiPLI: c_int`
//! - `pub const vpiRun: c_int`
//! - `pub const vpiNotice: c_int`
//! - `pub const vpiWarning: c_int`
//! - `pub const vpiError: c_int`
//! - `pub const vpiSystem: c_int`
//! - `pub const vpiInternal: c_int`
//! - `pub const vpiTimeQueue: c_int`
//! - `pub const vpiStop: c_int`
//! - `pub const vpiFinish: c_int`
//! - `pub const vpiReset: c_int`
//! - `pub const vpiSetInteractiveScope: c_int`
//! - `pub const vpiRejectTransientStep: c_int`
//! - `pub const vpiTransientFailConverge: c_int`
//! - `pub const vpiSysTask: c_int`
//! - `pub const vpiSysFunc: c_int`
//! - `pub const vpiAnalogSysTask: c_int`
//! - `pub const vpiAnalogSysFunc: c_int`
//! - `pub const vpiDerivative: c_int`
//! - `pub const vpiUserSystf: c_int`
//! - `pub const vpiSysTfCall: c_int`
//! - `pub const vpiInterModPath: c_int`
//! - `pub const vpiUserDefn: c_int`
//! - `pub const vpiSysFuncType: c_int`
//! - `pub const vpiBinStrVal: c_int`
//! - `pub const vpiOctStrVal: c_int`
//! - `pub const vpiDecStrVal: c_int`
//! - `pub const vpiHexStrVal: c_int`
//! - `pub const vpiScalarVal: c_int`
//! - `pub const vpiIntVal: c_int`
//! - `pub const vpiRealVal: c_int`
//! - `pub const vpiStringVal: c_int`
//! - `pub const vpiVectorVal: c_int`
//! - `pub const vpiStrengthVal: c_int`
//! - `pub const vpiTimeVal: c_int`
//! - `pub const vpiObjTypeVal: c_int`
//! - `pub const vpiSuppressVal: c_int`
//! - `pub const vpi0: c_int`
//! - `pub const vpi1: c_int`
//! - `pub const vpiZ: c_int`
//! - `pub const vpiX: c_int`
//! - `pub const vpiH: c_int`
//! - `pub const vpiL: c_int`
//! - `pub const vpiStrongDrive: c_int`
//! - `pub const vpiNoDelay: c_int`
//! - `pub const vpiInertialDelay: c_int`
//! - `pub const vpiTransportDelay: c_int`
//! - `pub const vpiPureTransportDelay: c_int`
//! - `pub const vpiForceFlag: c_int`
//! - `pub const vpiReleaseFlag: c_int`
//! - `pub const vpiCancelEvent: c_int`
//! - `pub const vpiReturnEvent: c_int`
//! - `pub const vpiSchedEvent: c_int`
//! - `pub const vpiScheduled: c_int`

const std = @import("std");
const abi = @import("abi.zig");
const callback = @import("callback.zig");
const callback_fire = @import("callback_fire.zig");
const handle = @import("handle.zig");
const property = @import("property.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const trust = @import("trust.zig");
const value = @import("value.zig");
const value_put = @import("value_put.zig");
const CbData = abi.CbData;
const ErrorInfo = abi.ErrorInfo;
const Event = value_put.Event;
const Harness = run.Harness;
const Time = abi.Time;
const Value = abi.Value;

/// §12.10's `vpExpStrVal` (Table 12-2's spelling): vpi_user.h's number.
pub const vpiExpStrVal: c_int = 710;

// s_vpi_time.type — §12.15.
pub const vpiScaledRealTime: c_int = 1;

pub const vpiSimTime: c_int = 2;
pub const vpiSuppressTime: c_int = 3;

/// §12.15 "scaled real, analog, or simulation time": the analog time, in
/// seconds, in `real`. The LRM gives it no number; this is VerA's (vpi_user.h).
pub const vpiAnalogTime: c_int = 4;

// §12.31 reasons, Annex G numbering.
pub const cbValueChange: c_int = 1;

pub const cbStmt: c_int = 2;
pub const cbForce: c_int = 3;
pub const cbRelease: c_int = 4;
pub const cbAtStartOfSimTime: c_int = 5;
pub const cbReadWriteSynch: c_int = 6;
pub const cbReadOnlySynch: c_int = 7;
pub const cbNextSimTime: c_int = 8;
pub const cbAfterDelay: c_int = 9;
pub const cbEndOfCompile: c_int = 10;
pub const cbStartOfSimulation: c_int = 11;
pub const cbEndOfSimulation: c_int = 12;
pub const cbError: c_int = 13;
pub const cbTchkViolation: c_int = 14;
pub const cbStartOfReset: c_int = 19;
pub const cbEndOfReset: c_int = 20;
pub const cbInteractiveScopeChange: c_int = 23;
pub const cbAssign: c_int = 25;
pub const cbDeassign: c_int = 26;
pub const cbDisable: c_int = 27;
pub const cbPLIError: c_int = 28;

// §12.31.3 the analog reasons. Verilog-AMS names them and numbers none; the
// numbers are VerA's, shared by vpi_user.h and
// tests/conformance/tests/verilog-ams/ch12_vpi_routines/p03_vpi_analog.h.
pub const acbInitialStep: c_int = 701;

pub const acbFinalStep: c_int = 702;
pub const acbAbsTime: c_int = 703;
pub const acbElapsedTime: c_int = 704;
pub const acbConvergenceTest: c_int = 705;
pub const acbAcceptedPoint: c_int = 706;

/// §11.6.25's callback object, as `vpi_get(vpiType, cb)` reports it.
pub const vpiCallback: c_int = 107;

// Annex G object types (IEEE 1364-2005, which §12.2 and §12.31 defer to).
pub const vpiAlways: c_int = 1;

pub const vpiAssignStmt: c_int = 2;
pub const vpiAssignment: c_int = 3;
pub const vpiBegin: c_int = 4;
pub const vpiCase: c_int = 5;
pub const vpiCaseItem: c_int = 6;
pub const vpiContAssign: c_int = 8;
pub const vpiDeassign: c_int = 9;
pub const vpiDelayControl: c_int = 11;
pub const vpiDisable: c_int = 12;
pub const vpiEventControl: c_int = 13;
pub const vpiEventStmt: c_int = 14;
pub const vpiFor: c_int = 15;
pub const vpiForce: c_int = 16;
pub const vpiForever: c_int = 17;
pub const vpiFork: c_int = 18;
pub const vpiFuncCall: c_int = 19;
pub const vpiFunction: c_int = 20;
pub const vpiIf: c_int = 22;
pub const vpiIfElse: c_int = 23;
pub const vpiInitial: c_int = 24;
pub const vpiAttribute: c_int = 105;
pub const vpiDefAttribute: c_int = 55;
pub const vpiIODecl: c_int = 28;
pub const vpiNamedBegin: c_int = 33;
pub const vpiNamedEvent: c_int = 34;
pub const vpiNamedEventArray: c_int = 129;
pub const vpiNamedFork: c_int = 35;
pub const vpiNetBit: c_int = 37;
pub const vpiNullStmt: c_int = 38;
pub const vpiOperation: c_int = 39;
pub const vpiPartSelect: c_int = 42;

/// IEEE 1364-2005 §26.6.26 (Annex G).
pub const vpiIndexedPartSelect: c_int = 130;

pub const vpiRegBit: c_int = 49;
pub const vpiRelease: c_int = 50;
pub const vpiRepeat: c_int = 51;
pub const vpiRepeatControl: c_int = 52;
pub const vpiSysFuncCall: c_int = 56;
pub const vpiSysTaskCall: c_int = 57;
pub const vpiTask: c_int = 59;
pub const vpiTaskCall: c_int = 60;
pub const vpiWait: c_int = 69;
pub const vpiWhile: c_int = 70;
pub const vpiParamAssign: c_int = 40;
pub const vpiGate: c_int = 21;
pub const vpiPrimTerm: c_int = 46;
pub const vpiTableEntry: c_int = 58;
pub const vpiUdp: c_int = 65;
pub const vpiUdpDefn: c_int = 66;
pub const vpiPrimitive: c_int = 103;
pub const vpiPrimType: c_int = 33;
pub const vpiTermIndex: c_int = 30;
pub const vpiSwitch: c_int = 55;
pub const vpiPullupPrim: c_int = 25;
pub const vpiPulldownPrim: c_int = 26;
pub const vpiStrength0: c_int = 31;
pub const vpiStrength1: c_int = 32;
pub const vpiSeqPrim: c_int = 27;
pub const vpiCombPrim: c_int = 28;

// Annex G relationships.
pub const vpiCondition: c_int = 71;

pub const vpiDelay: c_int = 72;
pub const vpiElseStmt: c_int = 73;
pub const vpiForIncStmt: c_int = 74;
pub const vpiForInitStmt: c_int = 75;
pub const vpiLhs: c_int = 77;
pub const vpiHighConn: c_int = 76;
pub const vpiLowConn: c_int = 80;
pub const vpiLeftRange: c_int = 79;
pub const vpiRhs: c_int = 82;
pub const vpiArgument: c_int = 89;
pub const vpiOperand: c_int = 97;
pub const vpiProcess: c_int = 99;
pub const vpiExpr: c_int = 102;
pub const vpiBaseExpr: c_int = 131;
pub const vpiWidthExpr: c_int = 132;

/// IEEE 1364-2005 §26.6.22/§26.6.23.
pub const vpiDriver: c_int = 91;

pub const vpiLoad: c_int = 93;
pub const vpiLocalDriver: c_int = 122;
pub const vpiLocalLoad: c_int = 123;

// §11.6.15 (IEEE 1364 Annex G numbering): module paths, path terms, timing
// checks and their terms, the relations between them, and their properties.
pub const vpiModPath: c_int = 31;

pub const vpiPathTerm: c_int = 43;
pub const vpiTchk: c_int = 61;
pub const vpiTchkTerm: c_int = 62;
pub const vpiTchkDataTerm: c_int = 86;
pub const vpiTchkNotifier: c_int = 87;
pub const vpiTchkRefTerm: c_int = 88;
pub const vpiModPathIn: c_int = 95;
pub const vpiModPathOut: c_int = 96;
pub const vpiModDataPathIn: c_int = 94;
pub const vpiModPathHasIfNone: c_int = 71;
pub const vpiEdge: c_int = 36;
pub const vpiPathType: c_int = 37;
pub const vpiPolarity: c_int = 34;
pub const vpiDataPolarity: c_int = 35;
pub const vpiTchkType: c_int = 38;
pub const vpiPathFull: c_int = 1;
pub const vpiPathParallel: c_int = 2;
pub const vpiPositive: c_int = 1;
pub const vpiNegative: c_int = 2;
pub const vpiUnknown: c_int = 3;
pub const vpiNoEdge: c_int = 0x00;
pub const vpiPosedge: c_int = 0x0D;
pub const vpiNegedge: c_int = 0x32;
pub const vpiAnyEdge: c_int = 0x3F;
pub const vpiStmt: c_int = 104;
pub const vpiRightRange: c_int = 83;

/// IEEE 1364-2005 §26.6.10 an array's range.
pub const vpiRange: c_int = 115;

/// IEEE 1364-2005 §26.6.44 (Annex G).
pub const vpiGenScopeArray: c_int = 133;

pub const vpiGenScope: c_int = 134;
pub const vpiImplicitDecl: c_int = 26;

// Annex G properties.
pub const vpiOpType: c_int = 39;

pub const vpiBlocking: c_int = 41;
pub const vpiCaseType: c_int = 42;
pub const vpiNetDeclAssign: c_int = 43;
pub const vpiFuncType: c_int = 44;

// vpiFuncType values (Annex G).
pub const vpiIntFunc: c_int = 1;

pub const vpiRealFunc: c_int = 2;
pub const vpiTimeFunc: c_int = 3;
pub const vpiSizedFunc: c_int = 4;
pub const vpiSizedSignedFunc: c_int = 5;
pub const vpiConnByName: c_int = 21;
pub const vpiIndexedPartSelectType: c_int = 72;
pub const vpiPosIndexed: c_int = 1;
pub const vpiNegIndexed: c_int = 2;

// vpiConstType values of a based literal (Annex G).
pub const vpiBinaryConst: c_int = 3;

pub const vpiOctConst: c_int = 4;
pub const vpiHexConst: c_int = 5;

// vpiCaseType values.
pub const vpiCaseExact: c_int = 1;

pub const vpiCaseX: c_int = 2;
pub const vpiCaseZ: c_int = 3;

// vpiOpType values.
pub const vpiMinusOp: c_int = 1;

pub const vpiPlusOp: c_int = 2;
pub const vpiNotOp: c_int = 3;
pub const vpiBitNegOp: c_int = 4;
pub const vpiUnaryAndOp: c_int = 5;
pub const vpiUnaryNandOp: c_int = 6;
pub const vpiUnaryOrOp: c_int = 7;
pub const vpiUnaryNorOp: c_int = 8;
pub const vpiUnaryXorOp: c_int = 9;
pub const vpiUnaryXNorOp: c_int = 10;
pub const vpiSubOp: c_int = 11;
pub const vpiDivOp: c_int = 12;
pub const vpiModOp: c_int = 13;
pub const vpiEqOp: c_int = 14;
pub const vpiNeqOp: c_int = 15;
pub const vpiCaseEqOp: c_int = 16;
pub const vpiCaseNeqOp: c_int = 17;
pub const vpiGtOp: c_int = 18;
pub const vpiGeOp: c_int = 19;
pub const vpiLtOp: c_int = 20;
pub const vpiLeOp: c_int = 21;
pub const vpiLShiftOp: c_int = 22;
pub const vpiRShiftOp: c_int = 23;
pub const vpiAddOp: c_int = 24;
pub const vpiMultOp: c_int = 25;
pub const vpiLogAndOp: c_int = 26;
pub const vpiLogOrOp: c_int = 27;
pub const vpiBitAndOp: c_int = 28;
pub const vpiBitOrOp: c_int = 29;
pub const vpiBitXorOp: c_int = 30;
pub const vpiBitXNorOp: c_int = 31;
pub const vpiConditionOp: c_int = 32;
pub const vpiConcatOp: c_int = 33;
pub const vpiMultiConcatOp: c_int = 34;
pub const vpiEventOrOp: c_int = 35;
pub const vpiListOp: c_int = 37;
pub const vpiPosedgeOp: c_int = 39;
pub const vpiNegedgeOp: c_int = 40;
pub const vpiArithLShiftOp: c_int = 41;
pub const vpiArithRShiftOp: c_int = 42;
pub const vpiPowerOp: c_int = 43;

// Verilog-AMS names these and numbers none; VerA's numbers, beside the
// analog classes of root.zig.
/// §11.6.21's `analog` process.
pub const vpiAnalog: c_int = 733;

/// §11.6.20 a contribution statement; `vpiDirect`/`vpiFlow` tell the four
/// members of the class apart.
pub const vpiContrib: c_int = 734;

pub const vpiDirect: c_int = 735;

/// §11.6.19 `accessfunc`, an access function applied to a branch or nodes.
pub const vpiAccessFunc: c_int = 736;

// §12.18's analysis properties. Verilog-AMS names them and numbers none;
// VerA's numbers, after the analog systf types.
pub const vpiStartTime: c_int = 742;

pub const vpiEndTime: c_int = 743;
pub const vpiTransientMaxStep: c_int = 744;
pub const vpiStartFrequency: c_int = 745;
pub const vpiEndFrequency: c_int = 746;

// §11.6 object types.
pub const vpiConstant: c_int = 7;

pub const vpiIntegerVar: c_int = 25;
pub const vpiIterator: c_int = 27;
pub const vpiMemory: c_int = 29;
pub const vpiMemoryWord: c_int = 30;
pub const vpiRealVar: c_int = 47;
pub const vpiVarSelect: c_int = 68;
pub const vpiModuleArray: c_int = 112;
pub const vpiRegArray: c_int = 116;
pub const vpiTimeVar: c_int = 63;
pub const vpiNetArray: c_int = 114;

/// IEEE 1364-2005 §26.6.1 module ->> variables.
pub const vpiVariables: c_int = 100;

/// IEEE 1364-2005 §26.6.20 (Annex G).
pub const vpiAutomatic: c_int = 50;

// §11.6.2/§11.6.5–§11.6.7, the analog classes. Verilog-AMS names these and
// numbers none; VerA's numbers, shared with tests/conformance/tests/verilog-ams/ch12_vpi_routines/
// p03_vpi_analog.h so a plugin including both sees one value per name.
pub const vpiQuantity: c_int = 720;

pub const vpiBranch: c_int = 721;
pub const vpiPotential: c_int = 722;
pub const vpiFlow: c_int = 723;
pub const vpiPosNode: c_int = 724;
pub const vpiNegNode: c_int = 725;
pub const vpiNode: c_int = 726;
pub const vpiDiscipline: c_int = 727;
pub const vpiNature: c_int = 728;
pub const vpiFlowNature: c_int = 729;
pub const vpiPotentialNature: c_int = 731;
pub const vpiChild: c_int = 732;

// §11.6.10/§11.6.11 relationships and properties.
pub const vpiArray: c_int = 28;

pub const vpiIsMemory: c_int = 73;
pub const vpiIndex: c_int = 78;
pub const vpiParent: c_int = 81;
pub const vpiDecConst: c_int = 1;
pub const vpiModule: c_int = 32;
pub const vpiNet: c_int = 36;
pub const vpiParameter: c_int = 41;
pub const vpiPort: c_int = 44;
pub const vpiReg: c_int = 48;

// Relationships.
pub const vpiScope: c_int = 84;

pub const vpiInternalScope: c_int = 92;

/// IEEE 1364-2005 §26.6.5-§26.6.7 vector ->> bit.
pub const vpiBit: c_int = 90;

/// IEEE 1364-2005 §26.6.43 (Annex G).
pub const vpiUse: c_int = 101;

pub const vpiIteratorType: c_int = 57;
pub const vpiActiveTimeFormat: c_int = 119;

// Properties.
pub const vpiUndefined: c_int = -1;

pub const vpiType: c_int = 1;
pub const vpiName: c_int = 2;
pub const vpiFullName: c_int = 3;
pub const vpiSize: c_int = 4;
pub const vpiTopModule: c_int = 7;
pub const vpiFile: c_int = 5;
pub const vpiLineNo: c_int = 6;
pub const vpiNetType: c_int = 22;
pub const vpiProtected: c_int = 10;
pub const vpiTimeUnit: c_int = 11;
pub const vpiTimePrecision: c_int = 12;
pub const vpiDefName: c_int = 9;
pub const vpiCell: c_int = 51;
pub const vpiConfig: c_int = 52;
pub const vpiLibrary: c_int = 58;
pub const vpiScalar: c_int = 17;
pub const vpiVector: c_int = 18;
pub const vpiDirection: c_int = 20;
pub const vpiPortIndex: c_int = 29;
pub const vpiConstType: c_int = 40;
pub const vpiSigned: c_int = 65;
pub const vpiLocalParam: c_int = 70;
pub const vpiDecompile: c_int = 54;

// §6.5.2.2 directions.
pub const vpiInput: c_int = 1;

pub const vpiOutput: c_int = 2;
pub const vpiInout: c_int = 3;
pub const vpiMixedIO: c_int = 4;
pub const vpiNoDirection: c_int = 5;

// §11.6.12 constant subtypes, over §3.4.1's parameter types.
pub const vpiRealConst: c_int = 2;

pub const vpiStringConst: c_int = 6;
pub const vpiIntConst: c_int = 7;

// §12.2 error state, and Table 12-1's severity ladder.
pub const vpiCompile: c_int = 1;

pub const vpiPLI: c_int = 2;
pub const vpiRun: c_int = 3;
pub const vpiNotice: c_int = 1;
pub const vpiWarning: c_int = 2;
pub const vpiError: c_int = 3;
pub const vpiSystem: c_int = 4;
pub const vpiInternal: c_int = 5;

/// §11.6.25's object type, Annex G numbering.
pub const vpiTimeQueue: c_int = 64;

// §12.36 operations, Annex G numbering.
pub const vpiStop: c_int = 66;

pub const vpiFinish: c_int = 67;
pub const vpiReset: c_int = 68;
pub const vpiSetInteractiveScope: c_int = 69;

/// VAMS §12.36 names it and gives no number; VerA allocates it (vpi_user.h).
pub const vpiRejectTransientStep: c_int = 730;

/// VAMS §12.36, likewise VerA's number.
pub const vpiTransientFailConverge: c_int = 731;

// §12.33.1 type / sysfunctype, Annex G numbering. VAMS spells the function
// type vpiSysFunction; Annex G spells it vpiSysFunc. Same number.
pub const vpiSysTask: c_int = 1;

pub const vpiSysFunc: c_int = 2;

// §12.32.1. Verilog-AMS names these and numbers none of them; the numbers are
// VerA's, shared with p03_vpi_analog.h.
pub const vpiAnalogSysTask: c_int = 740;

pub const vpiAnalogSysFunc: c_int = 741;
pub const vpiDerivative: c_int = 730;
pub const vpiUserSystf: c_int = 67;
pub const vpiSysTfCall: c_int = 85;
pub const vpiInterModPath: c_int = 26;

/// §11.6.16's call properties. Annex G numbers vpiSysFuncType as vpiFuncType.
pub const vpiUserDefn: c_int = 45;

pub const vpiSysFuncType: c_int = 44;

// Table 12-4 formats, Annex G numbering.
pub const vpiBinStrVal: c_int = 1;

pub const vpiOctStrVal: c_int = 2;
pub const vpiDecStrVal: c_int = 3;
pub const vpiHexStrVal: c_int = 4;
pub const vpiScalarVal: c_int = 5;
pub const vpiIntVal: c_int = 6;
pub const vpiRealVal: c_int = 7;
pub const vpiStringVal: c_int = 8;
pub const vpiVectorVal: c_int = 9;
pub const vpiStrengthVal: c_int = 10;
pub const vpiTimeVal: c_int = 11;
pub const vpiObjTypeVal: c_int = 12;
pub const vpiSuppressVal: c_int = 13;

// vpiScalarVal values.
pub const vpi0: c_int = 0;

pub const vpi1: c_int = 1;
pub const vpiZ: c_int = 2;
pub const vpiX: c_int = 3;
pub const vpiH: c_int = 4;
pub const vpiL: c_int = 5;

/// IEEE 1364-2005 Annex G's strength of a reg or variable.
pub const vpiStrongDrive: c_int = 0x40;

// §12.30 flags.
pub const vpiNoDelay: c_int = 1;

pub const vpiInertialDelay: c_int = 2;
pub const vpiTransportDelay: c_int = 3;
pub const vpiPureTransportDelay: c_int = 4;
pub const vpiForceFlag: c_int = 5;
pub const vpiReleaseFlag: c_int = 6;
pub const vpiCancelEvent: c_int = 7;
pub const vpiReturnEvent: c_int = 0x1000;
pub const vpiSchedEvent: c_int = 53;
pub const vpiScheduled: c_int = 46;

var overrides: [4][3]c_int = undefined;
var overrides_n: usize = 0;

// ---- private ----

/// The tests' registration of a time callback due at tick `low`.
fn registerAt(reason: c_int, low: c_uint) !void {
    std.debug.assert(callback.isTimeReason(reason));
    std.debug.assert(reason != cbNextSimTime);
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = low, .real = 0 };
    const d: CbData = .{ .reason = reason, .cb_rtn = callback.onStart, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (callback.vpi_register_cb(&d) == null) return error.TestUnexpectedResult;
}

/// The tests' read of `h` in one of the string formats.
fn getStr(h: abi.vpiHandle, format: c_int) []const u8 {
    std.debug.assert(format == vpiBinStrVal or format == vpiOctStrVal or format == vpiDecStrVal or format == vpiHexStrVal or format == vpiStringVal);
    var v: Value = std.mem.zeroes(Value);
    v.format = format;
    value.vpi_get_value(h, &v);
    std.debug.assert(v.format == format);
    return std.mem.span(v.value.str);
}

/// The tests' cbForce/cbRelease routine: records each override it hears.
fn noteOverride(d: *CbData) callconv(.c) c_int {
    std.debug.assert(overrides_n < overrides.len);
    std.debug.assert(d.value != null);
    overrides[overrides_n] = .{ d.reason, d.value.?.value.integer, @intFromBool(trust.asObj(d.obj) != null) };
    overrides_n += 1;
    return 0;
}

test "§12.31.2 nextDue: the earliest pending time callback; cbNextSimTime holds no time" {
    session.close();
    defer session.close();
    try registerAt(cbAfterDelay, 5);
    try registerAt(cbReadOnlySynch, 9);
    const next: CbData = .{ .reason = cbNextSimTime, .cb_rtn = callback.onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&next) != null);
    try std.testing.expectEqual(@as(?u64, 5), callback_fire.nextDue(0, true));
    try std.testing.expectEqual(@as(?u64, 5), callback_fire.nextDue(5, true));
    try std.testing.expectEqual(@as(?u64, 9), callback_fire.nextDue(5, false));
    try std.testing.expectEqual(@as(?u64, null), callback_fire.nextDue(9, false));
}

test "§12.16 Table 12-4: every string format over a four-state value" {
    var h: Harness = undefined;
    try h.init(
        \\module v;
        \\  reg [11:0] known, unknown;
        \\  reg [39:0] text;
        \\  reg signed [7:0] neg;
        \\  initial begin
        \\    known = 12'b1010_0111_0001;
        \\    unknown = 12'b1010_zzzz_01x1;
        \\    text = 40'h5665724121;
        \\    neg = -8'sd5;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const known = handle.vpi_handle_by_name("v.known", null);
    const unknown = handle.vpi_handle_by_name("v.unknown", null);
    try std.testing.expectEqualStrings("101001110001", getStr(known, vpiBinStrVal));
    try std.testing.expectEqualStrings("5161", getStr(known, vpiOctStrVal));
    try std.testing.expectEqualStrings("2673", getStr(known, vpiDecStrVal));
    try std.testing.expectEqualStrings("a71", getStr(known, vpiHexStrVal));
    try std.testing.expectEqualStrings("1010zzzz01x1", getStr(unknown, vpiBinStrVal));
    try std.testing.expectEqualStrings("azX", getStr(unknown, vpiHexStrVal));
    try std.testing.expectEqualStrings("5ZZX", getStr(unknown, vpiOctStrVal));
    try std.testing.expectEqualStrings("VerA!", getStr(handle.vpi_handle_by_name("v.text", null), vpiStringVal));
    try std.testing.expectEqualStrings("-5", getStr(handle.vpi_handle_by_name("v.neg", null), vpiDecStrVal));

    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    value.vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa05), v.value.integer);
    v.format = vpiVectorVal;
    value.vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa07), v.value.vector[0].aval);
    try std.testing.expectEqual(@as(c_int, 0x0f2), v.value.vector[0].bval);
    v.format = vpiObjTypeVal;
    value.vpi_get_value(known, &v);
    try std.testing.expectEqual(vpiVectorVal, v.format);
    // A format the routine does not read, and a handle that is not an object.
    v.format = 99;
    value.vpi_get_value(known, &v);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
    value.vpi_get_value(null, &v);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
}

test "§12.30: vpiNoDelay writes now, the delay modes schedule, and events cancel" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module p;
        \\  reg [7:0] q;
        \\  initial begin q = 0; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    const q = handle.vpi_handle_by_name("p.q", null);
    var v: Value = std.mem.zeroes(Value);
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = 5, .real = 0 };
    v.format = vpiHexStrVal;
    v.value.str = @constCast("a5");
    try std.testing.expect(value_put.vpi_put_value(q, &v, null, vpiNoDelay | vpiReturnEvent) == null);
    try std.testing.expectEqualStrings("10100101", getStr(q, vpiBinStrVal));

    v.format = vpiIntVal;
    v.value.integer = 0xAA;
    const aa = value_put.vpi_put_value(q, &v, &t, vpiPureTransportDelay | vpiReturnEvent);
    try std.testing.expect(aa != null);
    try std.testing.expectEqual(vpiSchedEvent, property.vpi_get(vpiType, aa));
    try std.testing.expectEqual(@as(c_int, 1), property.vpi_get(vpiScheduled, aa));
    // An inertial put removes the 0xAA event.
    v.value.integer = 0xCC;
    t.low = 10;
    try std.testing.expect(value_put.vpi_put_value(q, &v, &t, vpiInertialDelay) == null);
    try std.testing.expectEqual(@as(c_int, 0), property.vpi_get(vpiScheduled, aa));
    // Cancelling it again is not an error.
    _ = value_put.vpi_put_value(aa, null, null, vpiCancelEvent);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try run.simulate();
    v.format = vpiIntVal;
    value.vpi_get_value(q, &v);
    try std.testing.expectEqual(@as(c_int, 0xCC), v.value.integer);
}

test "§12.30: vpiForceFlag overrides a net's driver, vpiReleaseFlag hands it back" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module f;
        \\  reg [7:0] a;
        \\  wire [7:0] w;
        \\  assign w = a + 8'd1;
        \\  initial begin a = 10; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const w = handle.vpi_handle_by_name("f.w", null);
    var fmt: Value = std.mem.zeroes(Value);
    fmt.format = vpiIntVal;
    for ([_]c_int{ cbForce, cbRelease }) |reason| {
        const d: CbData = .{ .reason = reason, .cb_rtn = noteOverride, .obj = null, .time = null, .value = &fmt, .index = 0, .user_data = null };
        try std.testing.expect(callback.vpi_register_cb(&d) != null);
    }
    overrides_n = 0;
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    // A vpiNoDelay put overrides the resolved value until a driver changes
    // (IEEE 1364-2005 §27.32); a delayed one is refused.
    v.value.integer = 7;
    try std.testing.expect(value_put.vpi_put_value(w, &v, null, vpiNoDelay) == null);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    value.vpi_get_value(w, &v);
    try std.testing.expectEqual(@as(c_int, 7), v.value.integer);
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = 5, .real = 0 };
    try std.testing.expect(value_put.vpi_put_value(w, &v, &t, vpiInertialDelay) == null);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
    v.value.integer = 0xF0;
    try std.testing.expect(value_put.vpi_put_value(w, &v, null, vpiForceFlag) == null);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    v.value.integer = 0;
    value.vpi_get_value(w, &v);
    try std.testing.expectEqual(@as(c_int, 0xF0), v.value.integer);
    // Release: value_p comes back holding the driver's value, a + 1.
    v.value.integer = -1;
    _ = value_put.vpi_put_value(w, &v, null, vpiReleaseFlag);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 11), v.value.integer);
    // One cbForce carrying the forced value, one cbRelease the released one,
    // each naming the object.
    try std.testing.expectEqualSlices([3]c_int, &.{ .{ cbForce, 0xF0, 1 }, .{ cbRelease, 11, 1 } }, overrides[0..overrides_n]);
}

test "§12.16: an analog parameter reads the value lowering folded" {
    var res = try @import("vera").analyze(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real g = 2.5;
        \\  parameter integer k = 3;
        \\  analog I(p,n) <+ g*k*V(p,n);
        \\endmodule
    , .{}, null);
    defer res.deinit(std.testing.allocator);
    try session.open(std.testing.allocator, &res);
    defer session.close();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiRealVal;
    value.vpi_get_value(handle.vpi_handle_by_name("r.g", null), &v);
    try std.testing.expectEqual(@as(f64, 2.5), v.value.real);
    v.format = vpiObjTypeVal;
    value.vpi_get_value(handle.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(vpiIntVal, v.format);
    v.format = vpiIntVal;
    value.vpi_get_value(handle.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(@as(c_int, 3), v.value.integer);
    // A node's value lives in a device this process does not run.
    value.vpi_get_value(handle.vpi_handle_by_name("r.p", null), &v);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
}

test "§12.30: put refusals that need no design" {
    session.close();
    defer session.close();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    // Not a handle VerA issued: a cancel needs a vpiSchedEvent, any other put
    // an object.
    var junk: u32 = 0;
    try std.testing.expect(value_put.vpi_put_value(@ptrCast(&junk), null, null, vpiCancelEvent) == null);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
    try std.testing.expect(value_put.vpi_put_value(@ptrCast(&junk), &v, null, vpiNoDelay) == null);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
    // cbReadOnlySynch refuses every write before looking at the handle.
    run.read_only = true;
    defer run.read_only = false;
    try std.testing.expect(value_put.vpi_put_value(null, &v, null, vpiNoDelay) == null);
    var info: ErrorInfo = undefined;
    _ = status.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("READONLY", std.mem.span(info.code));
    // §12.16: NULL value_p.
    value.vpi_get_value(null, null);
    try std.testing.expectEqual(vpiError, status.vpi_chk_error(null));
    // A record with no run behind it is not scheduled, and its handle is not
    // live until a put returns it.
    const e: Event = .{ .handle = .{ .slot = .none, .generation = 0 }, .slot = 0, .time = 0 };
    try std.testing.expect(!value_put.scheduled(&e));
    try std.testing.expect(value_put.asEvent(@ptrCast(@constCast(&e))) == null);
    try std.testing.expect(value_put.asEvent(null) == null);
}
