#include <metal_stdlib>
using namespace metal;

struct NTMechanismInstruction {
    ushort opcode;
    ushort flags;
    uint operandA;
    uint operandB;
    float immediate;
};

struct NTMechanismProgram {
    uint instructionOffset;
    uint instructionCount;
    uint constantOffset;
    uint constantCount;
    uint routineOffset;
    uint routineCount;
    uint routineSlotOffset;
    uint routineSlotCount;
    uint integratorOffset;
    uint integratorCount;
    uint stateStride;
    uint maximumStackDepth;
    uint initialOffset;
    uint initialCount;
    uint breakpointOffset;
    uint breakpointCount;
    uint beforeStepOffset;
    uint beforeStepCount;
    uint afterStepOffset;
    uint afterStepCount;
    uint maximumCallDepth;
    uint sourceHashLo;
    uint sourceHashHi;
    uint flags;
};

struct NTMechanismRoutine {
    uint instructionOffset;
    uint instructionCount;
    uint slotOffset;
    uint argumentCount;
    uint localCount;
    uint kind;
    uint maximumStackDepth;
    uint flags;
};

struct NTMechanismIntegrator {
    uint stateOffset;
    uint derivativeOffset;
    uint method;
    uint routineIndex;
};

struct NTMechanismBuiltinSlots {
    uint voltage;
    uint dt;
    uint time;
    uint celsius;
};

struct NTMechanismInstance {
    uint programIndex;
    uint stateOffset;
    uint compartmentIndex;
    uint flags;
};

struct NTMechanismInput {
    float4 values;
};

struct NTMechanismParameters {
    float4 timing;
    uint4 counts;
};

struct NTMechanismEvent {
    uint kind;
    int flag;
    uint instanceIndex;
    uint reserved;
    float value;
    float timeFraction;
    float reserved2;
    float reserved3;
};

struct NTMechanismStatus {
    uint faultCode;
    uint instructionCount;
    uint eventCount;
    uint reserved;
};

struct NTMechanismFrame {
    uint returnPC;
    uint returnEnd;
    uint stackBase;
    uint wantsResult;
};

struct NTVMResult {
    uint fault;
    uint instructionCount;
    uint eventCount;
    uint resumePC;
    uint solveRoutine;
    uint solveMethod;
    float returnValue;
    bool returnedValue;
    bool requestedSolve;
};

enum NTOpcode : ushort {
    NTNoOperation = 0,
    NTPushConstant = 1,
    NTLoadVariable = 2,
    NTLoadIndexedVariable = 3,
    NTStoreVariable = 4,
    NTStoreIndexedVariable = 5,
    NTStoreDerivative = 6,
    NTAdd = 7,
    NTSubtract = 8,
    NTMultiply = 9,
    NTDivide = 10,
    NTPower = 11,
    NTNegate = 12,
    NTLogicalNot = 13,
    NTLess = 14,
    NTLessOrEqual = 15,
    NTGreater = 16,
    NTGreaterOrEqual = 17,
    NTEqual = 18,
    NTNotEqual = 19,
    NTLogicalAnd = 20,
    NTLogicalOr = 21,
    NTExponential = 22,
    NTLogarithm = 23,
    NTSquareRoot = 24,
    NTAbsolute = 25,
    NTSine = 26,
    NTCosine = 27,
    NTHyperbolicTangent = 28,
    NTFloor = 29,
    NTCeiling = 30,
    NTMinimum = 31,
    NTMaximum = 32,
    NTJump = 33,
    NTJumpIfZero = 34,
    NTCall = 35,
    NTReturnValue = 36,
    NTReturnVoid = 37,
    NTSolve = 38,
    NTConserve = 39,
    NTReaction = 40,
    NTEmitNetEvent = 41,
    NTWatch = 42,
    NTEnd = 43
};

enum NTFault : uint {
    NTFaultNone = 0,
    NTFaultProgram = 1,
    NTFaultInstruction = 2,
    NTFaultConstant = 3,
    NTFaultVariable = 4,
    NTFaultRoutine = 5,
    NTFaultJump = 6,
    NTFaultStackUnderflow = 7,
    NTFaultStackOverflow = 8,
    NTFaultCallDepth = 9,
    NTFaultInstructionBudget = 10,
    NTFaultDomain = 11,
    NTFaultNonFinite = 12,
    NTFaultEventOverflow = 13,
    NTFaultUnsupportedReaction = 14,
    NTFaultNestedSolve = 15,
    NTFaultIntegrator = 16
};

inline bool nt_push(thread float *stack, thread uint &sp, float value) {
    if (sp >= 128u || !isfinite(value)) { return false; }
    stack[sp++] = value;
    return true;
}

inline bool nt_pop(thread float *stack, thread uint &sp, thread float &value) {
    if (sp == 0u) { return false; }
    value = stack[--sp];
    return true;
}

inline bool nt_load(device float *state, uint stride, uint offset, thread float &value) {
    if (offset >= stride) { return false; }
    value = state[offset];
    return isfinite(value);
}

inline bool nt_store(device float *state, uint stride, uint offset, float value) {
    if (offset >= stride || !isfinite(value)) { return false; }
    state[offset] = value;
    return true;
}

inline bool nt_binary(thread float *stack, thread uint &sp, ushort opcode, thread uint &fault) {
    float rhs = 0.0f;
    float lhs = 0.0f;
    if (!nt_pop(stack, sp, rhs) || !nt_pop(stack, sp, lhs)) {
        fault = NTFaultStackUnderflow;
        return false;
    }
    float result = 0.0f;
    switch (opcode) {
        case NTAdd: result = lhs + rhs; break;
        case NTSubtract: result = lhs - rhs; break;
        case NTMultiply: result = lhs * rhs; break;
        case NTDivide:
            if (rhs == 0.0f) { fault = NTFaultDomain; return false; }
            result = lhs / rhs;
            break;
        case NTPower: result = pow(lhs, rhs); break;
        case NTLess: result = lhs < rhs ? 1.0f : 0.0f; break;
        case NTLessOrEqual: result = lhs <= rhs ? 1.0f : 0.0f; break;
        case NTGreater: result = lhs > rhs ? 1.0f : 0.0f; break;
        case NTGreaterOrEqual: result = lhs >= rhs ? 1.0f : 0.0f; break;
        case NTEqual: result = lhs == rhs ? 1.0f : 0.0f; break;
        case NTNotEqual: result = lhs != rhs ? 1.0f : 0.0f; break;
        case NTLogicalAnd: result = (lhs != 0.0f && rhs != 0.0f) ? 1.0f : 0.0f; break;
        case NTLogicalOr: result = (lhs != 0.0f || rhs != 0.0f) ? 1.0f : 0.0f; break;
        case NTMinimum: result = min(lhs, rhs); break;
        case NTMaximum: result = max(lhs, rhs); break;
        default: fault = NTFaultInstruction; return false;
    }
    if (!isfinite(result)) { fault = NTFaultNonFinite; return false; }
    if (!nt_push(stack, sp, result)) { fault = NTFaultStackOverflow; return false; }
    return true;
}

inline void nt_emit_event(
    device NTMechanismEvent *events,
    uint instanceIndex,
    uint eventStride,
    uint eventBase,
    thread NTVMResult &result,
    uint kind,
    int flag,
    float value
) {
    const uint localIndex = eventBase + result.eventCount;
    if (localIndex >= eventStride) {
        result.fault = NTFaultEventOverflow;
        return;
    }
    const uint eventIndex = instanceIndex * eventStride + localIndex;
    events[eventIndex].kind = kind;
    events[eventIndex].flag = flag;
    events[eventIndex].instanceIndex = instanceIndex;
    events[eventIndex].reserved = 0u;
    events[eventIndex].value = value;
    events[eventIndex].timeFraction = 0.0f;
    events[eventIndex].reserved2 = 0.0f;
    events[eventIndex].reserved3 = 0.0f;
    result.eventCount += 1u;
}

inline NTVMResult nt_run_vm(
    uint startPC,
    uint endPC,
    const thread NTMechanismProgram &program,
    device float *state,
    const device NTMechanismInstruction *instructions,
    const device float *constants,
    const device NTMechanismRoutine *routines,
    const device uint *routineSlots,
    device NTMechanismEvent *events,
    uint instanceIndex,
    uint eventStride,
    uint eventBase,
    uint instructionBudget,
    uint inheritedInstructionCount
) {
    NTVMResult output;
    output.fault = NTFaultNone;
    output.instructionCount = inheritedInstructionCount;
    output.eventCount = 0u;
    output.resumePC = endPC;
    output.solveRoutine = 0u;
    output.solveMethod = 0u;
    output.returnValue = 0.0f;
    output.returnedValue = false;
    output.requestedSolve = false;

    float stack[128];
    uint sp = 0u;
    NTMechanismFrame frames[8];
    uint frameDepth = 0u;
    uint pc = startPC;
    uint activeEnd = endPC;

    while (pc < activeEnd) {
        if (output.instructionCount >= instructionBudget) {
            output.fault = NTFaultInstructionBudget;
            break;
        }
        if (pc < program.instructionOffset || pc >= program.instructionOffset + program.instructionCount) {
            output.fault = NTFaultInstruction;
            break;
        }
        output.instructionCount += 1u;
        const NTMechanismInstruction instruction = instructions[pc++];
        float value = 0.0f;
        float rhs = 0.0f;

        switch (instruction.opcode) {
            case NTNoOperation: break;
            case NTPushConstant:
                if (instruction.operandA < program.constantOffset || instruction.operandA >= program.constantOffset + program.constantCount) {
                    output.fault = NTFaultConstant;
                    break;
                }
                if (!nt_push(stack, sp, constants[instruction.operandA])) { output.fault = NTFaultStackOverflow; }
                break;
            case NTLoadVariable:
                if (!nt_load(state, program.stateStride, instruction.operandA, value)) { output.fault = NTFaultVariable; break; }
                if (!nt_push(stack, sp, value)) { output.fault = NTFaultStackOverflow; }
                break;
            case NTLoadIndexedVariable:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                {
                    const int offset = int(instruction.operandA) + int(value);
                    if (offset < 0 || !nt_load(state, program.stateStride, uint(offset), value)) { output.fault = NTFaultVariable; break; }
                    if (!nt_push(stack, sp, value)) { output.fault = NTFaultStackOverflow; }
                }
                break;
            case NTStoreVariable:
            case NTStoreDerivative:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (!nt_store(state, program.stateStride, instruction.operandA, value)) { output.fault = NTFaultVariable; }
                break;
            case NTStoreIndexedVariable:
                if (!nt_pop(stack, sp, value) || !nt_pop(stack, sp, rhs)) { output.fault = NTFaultStackUnderflow; break; }
                {
                    const int offset = int(instruction.operandA) + int(value);
                    if (offset < 0 || !nt_store(state, program.stateStride, uint(offset), rhs)) { output.fault = NTFaultVariable; }
                }
                break;
            case NTAdd:
            case NTSubtract:
            case NTMultiply:
            case NTDivide:
            case NTPower:
            case NTLess:
            case NTLessOrEqual:
            case NTGreater:
            case NTGreaterOrEqual:
            case NTEqual:
            case NTNotEqual:
            case NTLogicalAnd:
            case NTLogicalOr:
            case NTMinimum:
            case NTMaximum:
                nt_binary(stack, sp, instruction.opcode, output.fault);
                break;
            case NTNegate:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (!nt_push(stack, sp, -value)) { output.fault = NTFaultStackOverflow; }
                break;
            case NTLogicalNot:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (!nt_push(stack, sp, value == 0.0f ? 1.0f : 0.0f)) { output.fault = NTFaultStackOverflow; }
                break;
            case NTExponential:
            case NTLogarithm:
            case NTSquareRoot:
            case NTAbsolute:
            case NTSine:
            case NTCosine:
            case NTHyperbolicTangent:
            case NTFloor:
            case NTCeiling:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (instruction.opcode == NTLogarithm && value <= 0.0f) { output.fault = NTFaultDomain; break; }
                if (instruction.opcode == NTSquareRoot && value < 0.0f) { output.fault = NTFaultDomain; break; }
                switch (instruction.opcode) {
                    case NTExponential: value = exp(value); break;
                    case NTLogarithm: value = log(value); break;
                    case NTSquareRoot: value = sqrt(value); break;
                    case NTAbsolute: value = fabs(value); break;
                    case NTSine: value = sin(value); break;
                    case NTCosine: value = cos(value); break;
                    case NTHyperbolicTangent: value = tanh(value); break;
                    case NTFloor: value = floor(value); break;
                    case NTCeiling: value = ceil(value); break;
                    default: break;
                }
                if (!isfinite(value)) { output.fault = NTFaultNonFinite; break; }
                if (!nt_push(stack, sp, value)) { output.fault = NTFaultStackOverflow; }
                break;
            case NTJump:
                if (instruction.operandA < program.instructionOffset || instruction.operandA > program.instructionOffset + program.instructionCount) {
                    output.fault = NTFaultJump;
                } else { pc = instruction.operandA; }
                break;
            case NTJumpIfZero:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (value == 0.0f) {
                    if (instruction.operandA < program.instructionOffset || instruction.operandA > program.instructionOffset + program.instructionCount) {
                        output.fault = NTFaultJump;
                    } else { pc = instruction.operandA; }
                }
                break;
            case NTCall:
                if (instruction.operandA < program.routineOffset || instruction.operandA >= program.routineOffset + program.routineCount) {
                    output.fault = NTFaultRoutine;
                    break;
                }
                if (frameDepth >= min(program.maximumCallDepth, 8u)) { output.fault = NTFaultCallDepth; break; }
                {
                    const NTMechanismRoutine routine = routines[instruction.operandA];
                    if (instruction.operandB != routine.argumentCount || sp < routine.argumentCount) { output.fault = NTFaultStackUnderflow; break; }
                    const uint argumentBase = sp - routine.argumentCount;
                    for (uint argument = 0u; argument < routine.argumentCount; ++argument) {
                        const uint slot = routineSlots[routine.slotOffset + argument];
                        if (!nt_store(state, program.stateStride, slot, stack[argumentBase + argument])) { output.fault = NTFaultVariable; break; }
                    }
                    if (output.fault != NTFaultNone) { break; }
                    sp = argumentBase;
                    for (uint local = 0u; local < routine.localCount; ++local) {
                        const uint slot = routineSlots[routine.slotOffset + routine.argumentCount + local];
                        if (!nt_store(state, program.stateStride, slot, 0.0f)) { output.fault = NTFaultVariable; break; }
                    }
                    if (output.fault != NTFaultNone) { break; }
                    frames[frameDepth].returnPC = pc;
                    frames[frameDepth].returnEnd = activeEnd;
                    frames[frameDepth].stackBase = sp;
                    frames[frameDepth].wantsResult = instruction.flags & 1u;
                    frameDepth += 1u;
                    pc = routine.instructionOffset;
                    activeEnd = routine.instructionOffset + routine.instructionCount;
                }
                break;
            case NTReturnValue:
            case NTReturnVoid:
                if (instruction.opcode == NTReturnValue) {
                    if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                }
                if (frameDepth == 0u) {
                    output.returnedValue = instruction.opcode == NTReturnValue;
                    output.returnValue = value;
                    pc = activeEnd;
                } else {
                    frameDepth -= 1u;
                    const NTMechanismFrame frame = frames[frameDepth];
                    pc = frame.returnPC;
                    activeEnd = frame.returnEnd;
                    sp = frame.stackBase;
                    if (frame.wantsResult != 0u) {
                        if (!nt_push(stack, sp, instruction.opcode == NTReturnValue ? value : 0.0f)) { output.fault = NTFaultStackOverflow; }
                    }
                }
                break;
            case NTSolve:
                if (frameDepth != 0u || sp != 0u) { output.fault = NTFaultNestedSolve; break; }
                if (instruction.operandA < program.routineOffset || instruction.operandA >= program.routineOffset + program.routineCount) { output.fault = NTFaultRoutine; break; }
                output.requestedSolve = true;
                output.solveRoutine = instruction.operandA;
                output.solveMethod = uint(instruction.flags);
                output.resumePC = pc;
                pc = activeEnd;
                break;
            case NTConserve:
                sp = 0u;
                break;
            case NTReaction:
                output.fault = NTFaultUnsupportedReaction;
                break;
            case NTEmitNetEvent:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                nt_emit_event(events, instanceIndex, eventStride, eventBase, output, 1u, 0, value);
                break;
            case NTWatch:
                if (!nt_pop(stack, sp, value)) { output.fault = NTFaultStackUnderflow; break; }
                if (value != 0.0f) { nt_emit_event(events, instanceIndex, eventStride, eventBase, output, 2u, int(instruction.operandA), value); }
                break;
            case NTEnd:
                pc = activeEnd;
                break;
            default:
                output.fault = NTFaultInstruction;
                break;
        }
        if (output.fault != NTFaultNone || output.requestedSolve) { break; }
    }
    return output;
}

inline uint nt_run_entry(
    uint start,
    uint count,
    const thread NTMechanismProgram &program,
    device float *state,
    const device NTMechanismInstruction *instructions,
    const device float *constants,
    const device NTMechanismRoutine *routines,
    const device uint *routineSlots,
    const device NTMechanismIntegrator *integrators,
    device NTMechanismEvent *events,
    uint instanceIndex,
    uint eventStride,
    uint instructionBudget,
    float dtMilliseconds,
    thread uint &instructionCount,
    thread uint &eventCount
) {
    uint pc = start;
    const uint end = start + count;
    while (pc < end) {
        NTVMResult result = nt_run_vm(
            pc, end, program, state, instructions, constants, routines, routineSlots,
            events, instanceIndex, eventStride, eventCount, instructionBudget, instructionCount
        );
        instructionCount = result.instructionCount;
        eventCount += result.eventCount;
        if (result.fault != NTFaultNone) { return result.fault; }
        if (!result.requestedSolve) { return NTFaultNone; }

        const NTMechanismRoutine routine = routines[result.solveRoutine];
        for (uint i = 0u; i < program.integratorCount; ++i) {
            const NTMechanismIntegrator integrator = integrators[program.integratorOffset + i];
            if (integrator.routineIndex != result.solveRoutine) { continue; }
            if (integrator.stateOffset >= program.stateStride || integrator.derivativeOffset >= program.stateStride) { return NTFaultIntegrator; }

            NTVMResult baseline = nt_run_vm(
                routine.instructionOffset, routine.instructionOffset + routine.instructionCount,
                program, state, instructions, constants, routines, routineSlots,
                events, instanceIndex, eventStride, eventCount, instructionBudget, instructionCount
            );
            instructionCount = baseline.instructionCount;
            eventCount += baseline.eventCount;
            if (baseline.fault != NTFaultNone) { return baseline.fault; }

            const float x = state[integrator.stateOffset];
            const float f0 = state[integrator.derivativeOffset];
            if (!isfinite(x) || !isfinite(f0)) { return NTFaultNonFinite; }
            const float epsilon = max(fabs(x) * 1.0e-4f, 1.0e-6f);
            state[integrator.stateOffset] = x + epsilon;
            NTVMResult perturbed = nt_run_vm(
                routine.instructionOffset, routine.instructionOffset + routine.instructionCount,
                program, state, instructions, constants, routines, routineSlots,
                events, instanceIndex, eventStride, eventCount, instructionBudget, instructionCount
            );
            instructionCount = perturbed.instructionCount;
            eventCount += perturbed.eventCount;
            if (perturbed.fault != NTFaultNone) { state[integrator.stateOffset] = x; return perturbed.fault; }
            const float f1 = state[integrator.derivativeOffset];
            state[integrator.stateOffset] = x;
            const float slope = (f1 - f0) / epsilon;
            const float intercept = f0 - slope * x;
            const uint method = integrator.method == 0u ? result.solveMethod : integrator.method;
            float updated = x + dtMilliseconds * f0;
            if (method == 1u && fabs(slope) > 1.0e-8f) {
                const float equilibrium = -intercept / slope;
                updated = equilibrium + (x - equilibrium) * exp(slope * dtMilliseconds);
            } else if (method == 2u && fabs(1.0f - dtMilliseconds * slope) > 1.0e-8f) {
                updated = (x + dtMilliseconds * intercept) / (1.0f - dtMilliseconds * slope);
            }
            if (!isfinite(updated)) { return NTFaultNonFinite; }
            state[integrator.stateOffset] = updated;
        }
        pc = result.resumePC;
    }
    return NTFaultNone;
}

kernel void nt_mechanism_execute_v2(
    const device NTMechanismProgram *programs [[buffer(0)]],
    const device NTMechanismInstruction *instructions [[buffer(1)]],
    const device float *constants [[buffer(2)]],
    const device NTMechanismRoutine *routines [[buffer(3)]],
    const device uint *routineSlots [[buffer(4)]],
    const device NTMechanismIntegrator *integrators [[buffer(5)]],
    const device NTMechanismBuiltinSlots *builtinSlots [[buffer(6)]],
    const device NTMechanismInstance *instances [[buffer(7)]],
    const device NTMechanismInput *inputs [[buffer(8)]],
    device float *state [[buffer(9)]],
    device NTMechanismEvent *events [[buffer(10)]],
    device NTMechanismStatus *statuses [[buffer(11)]],
    constant NTMechanismParameters &parameters [[buffer(12)]],
    uint instanceIndex [[thread_position_in_grid]]
) {
    const uint instanceCount = parameters.counts.x;
    if (instanceIndex >= instanceCount) { return; }
    const NTMechanismInstance instance = instances[instanceIndex];
    const NTMechanismProgram program = programs[instance.programIndex];
    const NTMechanismBuiltinSlots slots = builtinSlots[instance.programIndex];
    device float *instanceState = state + instance.stateOffset;
    const float4 input = inputs[instanceIndex].values;

    if (slots.voltage != 0xffffffffu && slots.voltage < program.stateStride) { instanceState[slots.voltage] = input.x; }
    if (slots.dt != 0xffffffffu && slots.dt < program.stateStride) { instanceState[slots.dt] = input.y; }
    if (slots.time != 0xffffffffu && slots.time < program.stateStride) { instanceState[slots.time] = input.z; }
    if (slots.celsius != 0xffffffffu && slots.celsius < program.stateStride) { instanceState[slots.celsius] = input.w; }

    uint instructionCount = 0u;
    uint eventCount = 0u;
    uint fault = NTFaultNone;
    const uint eventStride = parameters.counts.y;
    const uint instructionBudget = parameters.counts.z;
    const uint mode = parameters.counts.w;

    if (mode == 0u) {
        fault = nt_run_entry(
            program.initialOffset, program.initialCount, program, instanceState,
            instructions, constants, routines, routineSlots, integrators,
            events, instanceIndex, eventStride, instructionBudget, input.y,
            instructionCount, eventCount
        );
    } else {
        fault = nt_run_entry(
            program.beforeStepOffset, program.beforeStepCount, program, instanceState,
            instructions, constants, routines, routineSlots, integrators,
            events, instanceIndex, eventStride, instructionBudget, input.y,
            instructionCount, eventCount
        );
        if (fault == NTFaultNone) {
            fault = nt_run_entry(
                program.breakpointOffset, program.breakpointCount, program, instanceState,
                instructions, constants, routines, routineSlots, integrators,
                events, instanceIndex, eventStride, instructionBudget, input.y,
                instructionCount, eventCount
            );
        }
        if (fault == NTFaultNone) {
            fault = nt_run_entry(
                program.afterStepOffset, program.afterStepCount, program, instanceState,
                instructions, constants, routines, routineSlots, integrators,
                events, instanceIndex, eventStride, instructionBudget, input.y,
                instructionCount, eventCount
            );
        }
    }

    for (uint offset = 0u; offset < program.stateStride && fault == NTFaultNone; ++offset) {
        if (!isfinite(instanceState[offset])) { fault = NTFaultNonFinite; }
    }
    statuses[instanceIndex].faultCode = fault;
    statuses[instanceIndex].instructionCount = instructionCount;
    statuses[instanceIndex].eventCount = eventCount;
    statuses[instanceIndex].reserved = 0u;
}
