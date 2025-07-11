mutable struct IBM2D
    flags::KB.AM
    f2pd::FluidToPD
    pd2f::PDToFluid
    rv::ReferenceVariables

    function IBM2D(ps::KB.AbstractPhysicalSpace2D, ini_pos::Matrix{Float64}, ini_bc_edge::Dict{Int64, Vector{Vector{Vector{Float64}}}}, rv::ReferenceVariables)
        boundarys = Vector{Vector{Vector{Float64}}}()
        nodes = Vector{Int}()
        # 每个bm点与哪些个pd点相邻
        bm2pd = Dict{Vector{Float64}, Vector{Int}}()

        trans_para = rv.geo
        pos = compute_similarity_transform(ini_pos, trans_para)
        bc_edge = compute_similarity_transform(ini_bc_edge, trans_para)

        for (key, lines) in bc_edge
            for line in lines
                xbm1 = line[1][1:2]
                xbm2 = line[2][1:2]

                if haskey(bm2pd, xbm1)
                    push!(bm2pd[xbm1], key)
                else
                    bm2pd[xbm1] = []
                    push!(bm2pd[xbm1], key)
                end

                if haskey(bm2pd, xbm2)
                    push!(bm2pd[xbm2], key)
                else
                    bm2pd[xbm2] = []
                    push!(bm2pd[xbm2], key)
                end

                push!(boundarys, [xbm1, xbm2])
                push!(nodes, key)
            end
        end

        flags = build_flags(ps, boundarys)

        pd2flow = PDToFluid(ps, boundarys, bm2pd, flags)
        flow2pd = FluidToPD(ps, pos, nodes, boundarys, bm2pd, flags)

        new(flags, flow2pd, pd2flow, rv)
    end
end

function build_flags(ps::KB.AbstractPhysicalSpace2D, boundarys::Vector{Vector{Vector{Float64}}})
    flags = ones(Int, axes(ps.x))
    for i in axes(flags, 1), j in axes(flags, 2)
        point = [ps.x[i,j], ps.y[i,j]]
        if is_point_in_polygon(point, boundarys)
            flags[i, j] = 0
        end
    end
    flags[0, :] .= -1 # 左
    flags[ps.nx+1, :] .= -1 # 右
    flags[:, 0] .= -1 # 下
    flags[:, ps.ny+1] .= -1 # 上

    KB.ghost_flag!(ps, flags)
    
    return flags
end

function is_point_in_polygon(point::Vector{Float64}, polygon::Vector{Vector{Vector{Float64}}})
    x, y = point

    n = length(polygon)
    inside = false

    for i in 1:n
        x1, y1 = polygon[i][1]
        x2, y2 = polygon[i][2]
        
        if is_point_on_line_segment(point, polygon[i][1], polygon[i][2])
            return true
        end

        # 检查边是否跨越射线
        if ((y1 > y) != (y2 > y)) && (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1)
            inside = !inside
        end
    end
    
    return inside
end

function is_point_on_line_segment(p::Vector{Float64}, p1::Vector{Float64}, p2::Vector{Float64})::Bool
    x, y = p
    x1, y1 = p1
    x2, y2 = p2
    
    if p1 == p2
        return p == p1
    end

    # 计算向量叉积
    cross_product = (x - x1) * (y2 - y1) - (y - y1) * (x2 - x1)
    
    # 判断是否在直线上
    if cross_product != 0
        return false
    end
    
    # 判断点是否在端点之间
    if min(x1, x2) <= x <= max(x1, x2) && min(y1, y2) <= y <= max(y1, y2)
        return true
    else
        return false
    end
end

function are_points_on_the_same_side(A::Vector{Float64}, B::Vector{Float64}, l::Vector{Vector{Float64}})::Bool
    P = l[1]
    Q = l[2]

    # 计算向量 AB, AP, AQ
    PQ = Q - P
    PA = A - P
    PB = B - P

    # 计算叉积
    cross_p = PQ[1] * PA[2] - PQ[2] * PA[1]
    cross_q = PQ[1] * PB[2] - PQ[2] * PB[1]

    if cross_p * cross_q > 0
        return true
    else
        return false
    end
    return true
end

# 计算p关于直线p1p2的垂足
function foot(p::Vector{Float64}, p1::Vector{Float64}, p2::Vector{Float64})
    # 向量 A 和 B
    A = p2 .- p1
    B = p .- p1

    # 计算 t
    t = dot(A, B) / dot(A, A)

    # 计算垂足点
    foot = p1 .+ t .* A
    
    return foot
end

struct LineSegment
    p1::Vector{Float64}
    p2::Vector{Float64}
end

# 用于判断三个点的相对方向（顺时针、逆时针或共线）。
function orientation(p1::Vector{Float64}, p2::Vector{Float64}, p3::Vector{Float64})
    val = (p2[2] - p1[2]) * (p3[1] - p2[1]) - (p2[1] - p1[1]) * (p3[2] - p2[2])
    if val == 0
        return 0  # collinear
    elseif val > 0
        return 1  # clockwise
    else
        return 2  # counterclockwise
    end
end

# 用于判断一个点是否在一条线段上。
function on_segment(p::Vector{Float64}, q::Vector{Float64}, r::Vector{Float64})
    if q[1] <= max(p[1], r[1]) && q[1] >= min(p[1], r[1]) && q[2] <= max(p[2], r[2]) && q[2] >= min(p[2], r[2])
        return true
    end
    return false
end

# 用于判断两条线段是否相交。
function do_intersect(s1::LineSegment, s2::LineSegment)::Bool
    p1, q1 = s1.p1, s1.p2
    p2, q2 = s2.p1, s2.p2

    o1 = orientation(p1, q1, p2)
    o2 = orientation(p1, q1, q2)
    o3 = orientation(p2, q2, p1)
    o4 = orientation(p2, q2, q1)

    if o1 != o2 && o3 != o4
        return true
    end

    if o1 == 0 && on_segment(p1, p2, q1)
        return true
    end

    if o2 == 0 && on_segment(p1, q2, q1)
        return true
    end

    if o3 == 0 && on_segment(p2, p1, q2)
        return true
    end

    if o4 == 0 && on_segment(p2, q1, q2)
        return true
    end

    return false
end

function do_intersect(poly_vertices::Vector{Vector{Vector{Float64}}}, inside_point::Vector{Float64}, outside_point::Vector{Float64})
    
    s2 = LineSegment(inside_point, outside_point)

    for i in 1:size(poly_vertices, 1)
        s1 = LineSegment(poly_vertices[i][1], poly_vertices[i][2])
        if do_intersect(s1, s2)
            return i
        end
    end

    error("$(inside_point) 和 $(outside_point) 在多边形同一侧")
end