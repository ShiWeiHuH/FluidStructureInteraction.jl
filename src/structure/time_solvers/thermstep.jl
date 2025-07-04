"""
    Thermstep(; kwargs...) for thermal_timestep, MPI is yet not introduced.
"""
mutable struct Thermstep <: Peridynamics.AbstractTimeSolver
    end_time::Float64
    n_steps::Int
    Δt::Float64
    safety_factor::Float64

    function Thermstep(; time::Real=-1, steps::Int=-1, stepsize::Real=-1, safety_factor::Real=0.7)
        if time > 0 && steps > 0
            msg = "specify either time or number of steps, not both!"
            throw(ArgumentError(msg))
        elseif time < 0 && steps < 0
            msg = "specify either time or number of steps!"
            throw(ArgumentError(msg))
        end
        if !(0 < safety_factor < 1)
            msg = "wrong safety factor specified! condition: 0 < safety_factor < 1"
            throw(ArgumentError(msg))
        end
        if stepsize > 0
            @warn "stepsize specified! Please be sure that the CFD-condition holds!"
        end          
        new(time, steps, stepsize, safety_factor)
    end
end

function Base.show(io::IO, @nospecialize(vv::Thermstep))
    print(io, typeof(vv))
    fields = Vector{Symbol}()
    for field in fieldnames(typeof(vv))
        value = Peridynamics.getfield(vv, field)
        if value > 0
            push!(fields, field)
        end
    end
    print(io, Peridynamics.msg_fields_in_brackets(vv, Tuple(fields)))
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", @nospecialize(vv::Thermstep))
    if get(io, :compact, false)
        show(io, vv)
    else
        println(io, typeof(vv), ":")
        fields = Vector{Symbol}()
        for field in fieldnames(typeof(vv))
            value = Peridynamics.getfield(vv, field)
            if value > 0
                push!(fields, field)
            end
        end
        print(io, Peridynamics.msg_fields(vv, Tuple(fields)))
    end
    return nothing
end

function Peridynamics.init_time_solver!(vv::Thermstep, dh::Peridynamics.AbstractDataHandler)
    if vv.Δt < 0
        vv.Δt = calc_stable_timestep_th(dh, vv.safety_factor)
    end
    if vv.end_time < 0
        vv.end_time = vv.n_steps * vv.Δt
    elseif vv.n_steps < 0
        vv.n_steps = vv.end_time ÷ vv.Δt + 1
    end
    Thermstep_check(vv)
    return nothing
end

function Thermstep_check(vv::Thermstep)
    if vv.end_time < 0
        error("`end_time` of Thermstep smaller than zero!\n")
    end
    if vv.n_steps < 0
        error("`n_steps` of Thermstep smaller than zero!\n")
    end
    if vv.Δt < 0
        error("`Δt` of Thermstep smaller than zero!\n")
    end
    return nothing
end

#stable Δt 
function calc_stable_timestep_th(dh::Peridynamics.AbstractDataHandler, safety_factor::Float64)
    throw(MethodError(calc_stable_timestep_th, dh, safety_factor))
end

function calc_stable_timestep_th(dh::Peridynamics.ThreadsBodyDataHandler, safety_factor::Float64)
    Δt = zeros(length(dh.chunks))
    @threads :static for chunk_id in eachindex(dh.chunks)
        Δt[chunk_id] = calc_timestep_th(dh.chunks[chunk_id])
    end
    return minimum(Δt) * safety_factor
end

function calc_stable_timestep_th(dh::Peridynamics.ThreadsMultibodyDataHandler, safety_factor::Float64)
    Δt = minimum(calc_stable_timestep_th(bdh, safety_factor) for bdh in each_body_dh(dh))
    return Δt
end

function calc_stable_timestep_th(dh::Peridynamics.MPIBodyDataHandler, safety_factor::Float64)
    _Δt = calc_timestep_th(dh.chunk)
    Δt = MPI.Allreduce(_Δt, MPI.MIN, mpi_comm())
    return Δt * safety_factor
end

function calc_timestep_th(b::Peridynamics.AbstractBodyChunk)
    isempty(Peridynamics.each_point_idx(b)) && return Inf
    Δt = fill(Inf, length(Peridynamics.each_point_idx(b.system.chunk_handler)))
    for point_id in Peridynamics.each_point_idx(b.system.chunk_handler)
        pp = Peridynamics.get_params(b, point_id)
        Δt[point_id] = calc_timestep_point_th(b.system, pp, point_id)
    end
    return minimum(Δt)
end

# stable time step of thermal calculation
function calc_timestep_point_th(bd::Peridynamics.BondSystem, params::Peridynamics.AbstractPointParameters, point_id::Int)
    dtsum = 0.0
    for bond_id in Peridynamics.each_bond_idx(bd, point_id)
        bond = bd.bonds[bond_id]
        dtsum += bd.volume[bond.neighbor] * params.kp / bond.length
    end
    return  params.rho * params.cv / dtsum
end

function th_solve!(dh::Peridynamics.AbstractDataHandler, vv::Thermstep,
                  options::Peridynamics.AbstractJobOptions)
    Peridynamics.export_reference_results(dh, options)
    Δt = vv.Δt
    t_factors = modify_t(dh)
    conv, radi = find_sec_bcs_points(dh)
    if mpi_isroot()
        p = Progress(vv.n_steps; dt=1, desc="TIME INTEGRATION LOOP", color=:normal,
                     barlen=40, enabled=Peridynamics.progress_bars())
    end
    for n in 1:vv.n_steps
        th_timestep!(dh, options, Δt, n, t_factors, conv, radi)
        Peridynamics.mpi_isroot() && next!(p)
    end
    Peridynamics.mpi_isroot() && Peridynamics.finish!(p)
    return dh
end

function th_timestep!(dh::Peridynamics.AbstractThreadsBodyDataHandler, options::Peridynamics.AbstractJobOptions,
                          Δt::Float64, n::Int, t_factors::Vector{Vector{Float64}},
                          conv::Vector{Vector{Int}}, radi::Vector{Vector{Int}})
    t = n * Δt
    @threads :static for chunk_id in eachindex(dh.chunks)
        chunk = dh.chunks[chunk_id]
        Peridynamics.apply_boundary_conditions!(chunk, t)
        second_bcs!(chunk, conv[chunk_id], radi[chunk_id])
        update_temperature!(chunk, Δt)
    end

    @threads :static for chunk_id in eachindex(dh.chunks)
        Peridynamics.exchange_loc_to_halo!(dh, chunk_id)
        calc_pflux!(dh.chunks[chunk_id], t_factors[chunk_id]) 
    end

    @threads :static for chunk_id in eachindex(dh.chunks)
        Peridynamics.exchange_halo_to_loc!(dh, chunk_id)
        Peridynamics.export_results(dh, options, chunk_id, n, t)
    end
    #
    return nothing
end


function verlet_timestep!(dh::Peridynamics.AbstractMPIBodyDataHandler, options::Peridynamics.AbstractJobOptions,
                          Δt::Float64, Δt½::Float64, n::Int)
    t = n * Δt
    chunk = dh.chunk
    @timeit_debug TO "update_vel_half!" update_vel_half!(chunk, Δt½)
    @timeit_debug TO "apply_boundary_conditions!" apply_boundary_conditions!(chunk, t)
    @timeit_debug TO "update_disp_and_pos!" update_disp_and_pos!(chunk, Δt)
    @timeit_debug TO "exchange_loc_to_halo!" exchange_loc_to_halo!(dh)
    @timeit_debug TO "calc_force_density!" calc_force_density!(chunk)
    @timeit_debug TO "exchange_halo_to_loc!" exchange_halo_to_loc!(dh)
    @timeit_debug TO "calc_damage!" calc_damage!(chunk)
    @timeit_debug TO "update_acc_and_vel!" update_acc_and_vel!(chunk, Δt½)
    @timeit_debug TO "export_results" export_results(dh, options, n, t)
    return nothing
end


function Peridynamics.req_point_data_fields_timesolver(::Type{Thermstep})
    fields = (:position, :temperature, :pflux, :hsource)
    return fields
end

function Peridynamics.req_data_fields_timesolver(::Type{Thermstep})
    return ()
end

function Peridynamics.log_timesolver(options::Peridynamics.AbstractJobOptions, vv::Thermstep)
    msg = "VELOCITY VERLET TIME SOLVER\n"
    msg *= Peridynamics.msg_qty("number of time steps", vv.n_steps)
    msg *= Peridynamics.msg_qty("time step size", vv.Δt)
    msg *= Peridynamics.msg_qty("time step safety factor", vv.safety_factor)
    msg *= Peridynamics.msg_qty("simulation time", vv.end_time)
    Peridynamics.log_it(options, msg)
    return nothing
end

