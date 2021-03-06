module RigidBodySimTest

using Compat
using RigidBodyDynamics
using RigidBodySim

import JSON
import LCMCore: LCM, publish
import DiffEqCallbacks: DiscreteCallback
import DiffEqBase: add_tstop!
import OrdinaryDiffEq: Rodas4P
import MechanismGeometries
import RigidBodyTreeInspector
import MeshCatMechanisms
import MeshCat
import RigidBodySim.Visualization.RigidBodyTreeInspectorInterface

using Compat.Test

function send_control_message(lcm::LCM, contents::Associative)
    utime = round(Int, time() * 1e-3)
    format = "rigid_body_sim_json"
    version_major = 1
    version_minor = 1
    data = convert(Vector{UInt8}, JSON.json(contents))
    msg = RigidBodySim.LCMTypes.CommsT(utime, format, version_major, version_minor, data)
    publish(lcm, RigidBodyTreeInspectorInterface.LCM_CONTROL_CHANNEL, msg)
end

send_pause_message(lcm::LCM = LCM()) = send_control_message(lcm, Dict("pause" => nothing))
send_terminate_message(lcm::LCM = LCM()) = send_control_message(LCM(), Dict("terminate" => nothing))

function pause_message_sender(tpause::Number, pausecondition::Condition)
    havepaused = Ref(false)
    condition = (u, t, integrator) -> !havepaused[] && t >= tpause
    action = function (integrator)
        send_pause_message()
        notify(pausecondition)
        havepaused[] = true
    end
    initialize = (c, t, u, integrator) -> (havepaused[] = false; add_tstop!(integrator, tpause))
    DiscreteCallback(condition, action, save_positions=(false, false), initialize = initialize)
end

function dynamics_allocations(dynamics::Dynamics, state::MechanismState) # introduce function barrier
    x = Vector(state)
    ẋ = similar(x)
    p = nothing
    t = 3.
    dynamics(ẋ, x, p, t)
    allocs = @allocated dynamics(ẋ, x, p, t)
end

@testset "Dynamics" begin
    srand(134)
    mechanism = rand_tree_mechanism(Float64, [Revolute{Float64} for i = 1 : 30]...)
    dynamics = Dynamics(mechanism)
    state = MechanismState(mechanism)
    rand!(state)
    @test dynamics_allocations(dynamics, state) <= 80
end

@testset "compare to simulate" begin
    srand(1)

    urdf = Pkg.dir("RigidBodySim", "test", "urdf", "Acrobot.urdf")
    mechanism = parse_urdf(Float64, urdf)

    state = MechanismState(mechanism)
    rand!(state)
    x0 = Vector(state)

    final_time = 5.
    problem = ODEProblem(Dynamics(mechanism), state, (0., final_time))
    sol = solve(problem, Vern7(), abs_tol = 1e-10, dt = 0.05)

    copy!(state, x0)
    ts, qs, vs = RigidBodyDynamics.simulate(state, final_time)

    @test [qs[end]; vs[end]] ≈ sol[end] atol = 1e-2
end

function test_visualizer(mechanism, state, vis)
    if !haskey(ENV, "CI")
        window(vis)
    end
    visualize(vis, 0.0, state)

    dt = 1e-4
    tfinal = 0.5
    problem = ODEProblem(Dynamics(mechanism), state, (0., tfinal))
    vis_callbacks = CallbackSet(vis, state)

    # Simulate without interaction
    sol = solve(problem, RK4(), adaptive = false, dt = dt, callback = vis_callbacks)
    @test sol.t[end] == tfinal

    if RigidBodySim.Visualization.isinteractive(vis)
        tfinal = 100.
        problem = ODEProblem(Dynamics(mechanism), state, (0., tfinal))

        # Simulate for 3 seconds (wall time) and then send a termination command
        @async (sleep(3.); send_terminate_message())
        sol = solve(problem, RK4(), adaptive = false, dt = dt, callback = vis_callbacks)
        @test sol.t[end] > 2 * dt
        @test sol.t[end] < tfinal
        println("last(sol.t) after early termination 1: $(last(sol.t))")

        # Rinse and repeat with the same ODEProblem (make sure that we don't terminate straight away)
        send_terminate_message()
        sleep(0.1)
        @async (sleep(3.); send_terminate_message())
        sol = solve(problem, RK4(), adaptive = false, dt = dt, callback = vis_callbacks)
        @test sol.t[end] > 2 * dt
        @test sol.t[end] < tfinal
        println("last(sol.t) after early termination 2: $(last(sol.t))")

        # Pause and unpause a short simulation, make sure that the simulation takes longer than without pausing
        problem = ODEProblem(Dynamics(mechanism), state, (0., 1.))
        pausetime = 0.5
        pausecondition = Condition()
        pauser = pause_message_sender(pausetime, pausecondition)
        integrator = init(problem, RK4(), adaptive = false, dt = dt, callback = CallbackSet(vis_callbacks, pauser))
        havepaused = Ref(false)
        @async begin
            wait(pausecondition)
            sleep(0.5) # wait for message to reach command handler callback
            integrator_time = integrator.t
            @test integrator_time < pausetime + 0.1 # it takes a while for the pause message to reach the command handler callback
            sleep(2.)
            @test integrator.t == integrator_time # make sure simulation remains paused
            havepaused[] = true
            send_pause_message() # unpause
        end
        solve!(integrator)
        @test havepaused[]

        # Simulate for 3 seconds wall time, then pause, and then terminate a second later to make sure terminating works while paused
        problem = ODEProblem(Dynamics(mechanism), state, (0., tfinal))
        @async (sleep(3.); send_pause_message())
        @async (sleep(4.); send_terminate_message())
        sol = solve(problem, RK4(), adaptive = false, dt = dt, callback = vis_callbacks)
        @test sol.t[end] > 2 * dt
        @test sol.t[end] < tfinal
        println("last(sol.t) after early termination 3: $(last(sol.t))")
    end
end

@testset "visualizer callbacks" begin
    mechanism = rand_tree_mechanism(Float64, [Revolute{Float64} for i = 1 : 30]...)
    state = MechanismState(mechanism)

    visualizers = [
        MeshCatMechanisms.MechanismVisualizer(mechanism, MeshCatMechanisms.Skeleton(randomize_colors = true, inertias = false), MeshCat.Visualizer()),
        RigidBodyTreeInspector.Visualizer(mechanism; show_inertias = true)
    ]

    for vis in visualizers
        test_visualizer(mechanism, state, vis)
    end
end

@testset "renormalization callback" begin
    mechanism = rand_tree_mechanism(Float64, QuaternionFloating{Float64})
    floatingjoint = first(joints(mechanism))
    state = MechanismState(mechanism)

    rand!(configuration(state))
    @test !RigidBodyDynamics.is_configuration_normalized(floatingjoint, configuration(state, floatingjoint))

    problem = ODEProblem(Dynamics(mechanism), state, (0., 1e-3))
    sol = solve(problem, Vern7(), dt = 1e-4, callback = configuration_renormalizer(state))

    copy!(state, sol[end])
    @test RigidBodyDynamics.is_configuration_normalized(floatingjoint, configuration(state, floatingjoint))
end

@testset "RealtimeRateLimiter" begin
    du = [0; 0]
    u0 = [0.; 0.]
    dynamics = (u, p, t) -> eltype(u).(du)
    tmin = 10.1
    tmax = 12.2
    for max_rate in [2.0, 0.5]
        prob = ODEProblem(dynamics, u0, (tmin, tmax))
        rate_limiter = RealtimeRateLimiter(max_rate = max_rate)
        sol = solve(prob, Tsit5(); callback = rate_limiter)
        soltime = @elapsed solve(prob, Tsit5(); callback = rate_limiter)
        expected = (tmax - tmin) / max_rate
        @show soltime
        @show expected
        @test soltime ≈ expected atol = 0.5
    end
end

@testset "ODESolution animation" begin
    mechanism = rand_tree_mechanism(Float64, [Revolute{Float64} for i = 1 : 30]...)
    state = MechanismState(mechanism)

    vis = RigidBodyTreeInspector.Visualizer(mechanism; show_inertias = true)
    window(vis)

    final_time = 5.
    problem = ODEProblem(Dynamics(mechanism), state, (0., final_time))
    sol = solve(problem, Vern7(), abs_tol = 1e-10, dt = 0.05)

    # regular playback
    realtime_rate = 2.
    animate(vis, state, sol, realtime_rate = 1000.)
    elapsed = @elapsed animate(vis, state, sol, realtime_rate = realtime_rate, max_fps = 60.)
    @test elapsed ≈ final_time / realtime_rate atol = 0.1

    # premature termination
    termination_time = 1.5
    @async (sleep(termination_time); send_terminate_message())
    elapsed = @elapsed animate(vis, state, sol, realtime_rate = realtime_rate)
    @test elapsed ≈ termination_time atol = 0.1

    # pause and unpause
    pause_time = 1.0
    unpause_time = 3.5
    @async (sleep(pause_time); send_pause_message())
    @async (sleep(unpause_time); send_pause_message())
    elapsed = @elapsed animate(vis, state, sol, realtime_rate = realtime_rate)
    @show elapsed
    @test elapsed ≈ final_time / realtime_rate + (unpause_time - pause_time) atol = 0.2 # higher atol because of pause poll int

    # pause and terminate
    @async (sleep(pause_time); send_pause_message())
    @async (sleep(termination_time); send_terminate_message())
    elapsed = @elapsed animate(vis, state, sol, realtime_rate = realtime_rate)
    @show elapsed
    @test elapsed ≈ termination_time atol = 0.2 # higher atol because of pause poll int
end

@testset "PeriodicController" begin
    urdf = Pkg.dir("RigidBodySim", "test", "urdf", "Acrobot.urdf")
    mechanism = parse_urdf(Float64, urdf)
    state = MechanismState(mechanism)
    controltimes = Float64[]
    initialize = (c, u, t, integrator) -> empty!(controltimes)
    τ = similar(velocity(state))
    Δt = 0.25

    make_controller = function ()
        PeriodicController(τ, Δt, function (τ, t, state)
            push!(controltimes, t)
            τ[1] = sin(t)
            τ[2] = cos(t)
        end; initialize = initialize)
    end

    controller = make_controller()
    final_time = 25.3
    problem = ODEProblem(Dynamics(mechanism, controller), state, (0., final_time))

    # ensure that controller gets called at appropriate times:
    sol = solve(problem, Vern7(), abs_tol = 1e-10, dt = 0.05)
    @test controltimes == collect(0. : Δt : final_time - rem(final_time, Δt))

    # ensure that we can solve the same problem again without errors
    empty!(controltimes)
    sol = solve(problem, Vern7(), abs_tol = 1e-10, dt = 0.05)
    @test controltimes == collect(0. : Δt : final_time - rem(final_time, Δt))

    # issue #60
    empty!(controltimes)
    problem60 = ODEProblem(Dynamics(mechanism, (τ, t, state) -> controller(τ, t, state)), state, (0., final_time))
    @test_throws RigidBodySim.Control.PeriodicControlFailure solve(problem60, Vern7(), abs_tol = 1e-10, dt = 0.05)
    controller = controller = make_controller()
    problem60 = ODEProblem(Dynamics(mechanism, (τ, t, state) -> controller(τ, t, state)), state, (0., final_time))
    @test_throws RigidBodySim.Control.PeriodicControlFailure solve(problem60, Vern7(), abs_tol = 1e-10, dt = 0.05)
    problem60_fixed = ODEProblem(Dynamics(mechanism, (τ, t, state) -> controller(τ, t, state)), state, (0., final_time),
        callback = PeriodicCallback(controller))
    sol60 = solve(problem60_fixed, Vern7(), abs_tol = 1e-10, dt = 0.05)
    @test controltimes == collect(0. : Δt : final_time - rem(final_time, Δt))
    @test sol60.t == sol.t
    @test sol60.u == sol.u
end

@testset "Stiff integrator" begin
    urdf = Pkg.dir("RigidBodySim", "test", "urdf", "Acrobot.urdf")
    mechanism = parse_urdf(Float64, urdf)
    state = MechanismState(mechanism)
    srand(1)
    rand!(state)
    x0 = Vector(state)
    final_time = 1.
    problem = ODEProblem(Dynamics(mechanism), state, (0., final_time))

    sol_nonstiff = solve(problem, Vern7(), abs_tol = 1e-10, dt = 0.05)
    sol_stiff = solve(problem, Rodas4P(), abs_tol = 1e-10, dt = 0.05)
    @test last(sol_nonstiff) ≈ last(sol_stiff) atol = 1e-2
end

# notebooks
@testset "example notebooks" begin
    using NBInclude
    notebookdir = Pkg.dir("RigidBodySim", "notebooks")
    for file in readdir(notebookdir)
        name, ext = splitext(file)
        if lowercase(ext) == ".ipynb"
            @testset "$name" begin
                println("Testing $name.")
                nbinclude(joinpath(notebookdir, file), regex = r"^((?!\#NBSKIP).)*$"s)
            end
        end
    end
end

end
