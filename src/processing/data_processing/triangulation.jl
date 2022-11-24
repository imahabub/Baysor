import Distances

# @lazy import VoronoiDelaunay as VD = "72f80fcb-8c52-57d9-aff0-40c1a3526986"
import VoronoiDelaunay as VD # It causes world age issues
using StatsBase: countmap
using NearestNeighbors

import GeometricalPredicates
import GeometricalPredicates.getx, GeometricalPredicates.gety

struct IndexedPoint2D <: GeometricalPredicates.AbstractPoint2D
    _x::Float64
    _y::Float64
    _index::Int
    IndexedPoint2D(x::Float64,y::Float64, index::Int) = new(x, y, index)
end

IndexedPoint2D() = IndexedPoint2D(0., 0., 0)
IndexedPoint2D(x::Float64, y::Float64) = IndexedPoint2D(x, y, 0)

getx(p::IndexedPoint2D) = p._x
gety(p::IndexedPoint2D) = p._y
geti(p::IndexedPoint2D) = p._index

function adjacency_list(points::Matrix{<:Real}; filter::Bool=true, n_mads::Float64=2.0, k_adj::Int=5,
        adjacency_type::Symbol=:triangulation, distance::TD where TD <: Distances.SemiMetric = Euclidean())
    if size(points, 1) == 3
        (adjacency_type == :knn) || @warn "Only k-nn random field is supported for 3D data"
        adjacency_type = :knn
    else
        (size(points, 1) == 2) || error("Only 2D and 3D data is supported")
    end

    if !in(adjacency_type, (:knn, :triangulation, :both))
        error("Unknown adjacency type: $adjacency_type")
    end

    points = deepcopy(points)

    # Rescale to match the requirement for VoronoiDelaunay.jl: min_coord=1.0+eps(Float64) and max_coord=2.0-2eps(Float64)
    points .-= minimum(points, dims=2)
    points ./= maximum(points) * 1.1
    points .+= 1.01

    # Tesselation don't work with duplicated points. And in knn 0-distance points result in loop edges
    hashes = vec(mapslices(row -> "$(row[1]) $(row[2])", round.(points, digits=10), dims=1));
    is_duplicated = get.(Ref(countmap(hashes)), hashes, 0) .> 1;
    points[:, is_duplicated] .+= (rand(Float64, (size(points, 1), sum(is_duplicated))) .- 0.5) .* 2e-5;

    edge_list = Matrix{Int}(undef, 2,0)
    if (adjacency_type == :triangulation) || (adjacency_type == :both)
        points_g = [IndexedPoint2D(points[:,i]..., i) for i in 1:size(points, 2)];

        tess = VD.DelaunayTessellation2D(length(points_g), IndexedPoint2D());
        push!(tess, points_g);

        edge_list = hcat([geti.([VD.geta(v), VD.getb(v)]) for v in VD.delaunayedges(tess)]...);
    end

    if (adjacency_type == :knn) || (adjacency_type == :both)
        nns = knn(KDTree(points), points, k_adj + 1, true)[1];
        e_start = repeat(1:length(nns), inner=k_adj)
        e_end = vcat([es[2:end] for es in nns]...)
        edge_list = hcat(fmin.(e_start, e_end), fmax.(e_start, e_end));
        edge_list = unique(edge_list'; dims=2)
    end

    adj_dists = Distances.colwise(distance, points[:, edge_list[1,:]], points[:, edge_list[2,:]])

    if filter
        adj_dists_log = log10.(adj_dists)
        d_threshold = median(adj_dists_log) + n_mads * mad(adj_dists_log, normalize=true)

        filt_mask = (adj_dists_log .< d_threshold)
        edge_list = edge_list[:, filt_mask]
        adj_dists = adj_dists[filt_mask]
    end

    return edge_list, adj_dists
end

adjacency_list(spatial_df::DataFrame; kwargs...) = adjacency_list(position_data(spatial_df); kwargs...)
