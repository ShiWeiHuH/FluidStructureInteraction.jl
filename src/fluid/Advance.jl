function update_field!(
    KS::KitBase.SolverSet,
    ctr::KitBase.AM{TC}, 
    a1face::KitBase.AM{TF}, 
    a2face::KitBase.AM{TF}, 
    flags::KitBase.AM, 
    residual
) where {TC<:Union{ControlVolume,ControlVolume2D},TF<:Union{Interface,Interface2D}}
    nx, ny, dx, dy = KS.ps.nx, KS.ps.ny, KS.ps.dx, KS.ps.dy

    sumRes = zero(ctr[1].w)
    sumAvg = zero(ctr[1].w)


    @inbounds @threads for j ∈ 1:ny
        for i ∈ 1:nx
            if flags[i, j] == 1
                KB.step!(
                    ctr[i, j].w,
                    ctr[i, j].prim,
                    a1face[i, j].fw,
                    a1face[i+1, j].fw,
                    a2face[i, j].fw,
                    a2face[i, j+1].fw,
                    KS.gas.γ,
                    dx[i, j] * dy[i, j],
                    sumRes,
                    sumAvg,
                    :bgk,
                )
            end
        end
    end

    for i in eachindex(residual)
	    residual[i] = sqrt(sumRes[i] * nx * ny) / (sumAvg[i] + 1.e-7)
    end    

    # 设置边界条件
    direcs = [:xl, :xr, :yl, :yr]
    for iter in axes(KS.set.boundary, 1)
        if KS.set.boundary[iter] == "extra"
            KitBase.bc_extra!(ctr; dirc = direcs[iter])
        elseif KS.set.boundary[iter] == "mirror"
            KitBase.bc_mirror!(ctr; dirc = direcs[iter])
        end
    end

    return nothing
end

function ibm_step!(
    ks::KitBase.SolverSet, 
    ib::IBM2D, 
    ctr::KitBase.AM{TC}, 
    a1face::KB.AM{TF}, 
    a2face::KB.AM{TF}, 
    tt::Int,
    dtf::Float64, 
    options::Peridynamics.AbstractJobOptions
) where {TC<:Union{ControlVolume,ControlVolume2D},TF<:Union{Interface,Interface2D}}
    
    res = zeros(4)

    ibm_evolve!(ks, ctr, a1face, a2face, ib.flags, ib.pd2f.idgc, ib.pd2f.ctr, dtf)
    
    update_field!(ks, ctr, a1face, a2face, ib.flags, res)

    export_fluid(ks.ps, ctr, options, tt, dtf)
   
    return pressure
end