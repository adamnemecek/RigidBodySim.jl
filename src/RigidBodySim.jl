__precompile__()

module RigidBodySim

import DiffEqBase: ODEProblem, init, solve!, solve, CallbackSet
import DiffEqCallbacks: PeriodicCallback
import OrdinaryDiffEq: Tsit5, Vern7, RK4
import DrakeVisualizer: Visualizer, settransform!

include("core.jl")
include("control.jl")
include("lcmtypes.jl")
include("visualization.jl")

using .Core
using .Control
using .Visualization

# Select DifferentialEquations exports
export
    ODEProblem, # from DiffEqBase
    init, # from DiffEqBase
    solve!, # from DiffEqBase
    solve, # from DiffEqBase
    Tsit5, # from OrdinaryDiffEq
    Vern7, # from OrdinaryDiffEq
    RK4, # from OrdinaryDiffEq
    CallbackSet, # from DiffEqBase
    PeriodicCallback # from DiffEqCallbacks

# Core
export
    Dynamics,
    controlcallback,
    configuration_renormalizer,
    zero_control!,
    RealtimeRateLimiter

# Control
export
    PeriodicController

# Visualization
export
    animate,
    window,
    visualize

end # module
