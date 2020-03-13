using ProgressMeter
using DataFrames
using Statistics
using StatsBase
using Random

function maximize_mols!(cell_type_exprs::Matrix{Float64}, cell_type_exprs_norm::Matrix{Float64}, genes::Vector{Int}, assignment_probs::Matrix{Float64})
    cell_type_exprs .= 0.0;
    for i in 1:length(genes)
        t_gene = genes[i];
        for j in 1:size(cell_type_exprs, 1)
            cell_type_exprs[j, t_gene] += assignment_probs[j, i];
        end
    end

    cell_type_exprs .= (cell_type_exprs .+ 1) ./ (sum(cell_type_exprs, dims=2) .+ 1);
    cell_type_exprs_norm .= cell_type_exprs ./ sum(cell_type_exprs, dims=2);
end

function expect_mols!(assignment_probs::Matrix{Float64}, cell_type_exprs::Matrix{Float64}, cell_type_exprs_norm::Matrix{Float64}, genes::Vector{Int},
        adjacent_points::Vector{Vector{Int}}, adjacent_weights::Vector{Vector{Float64}}; new_prob::Float64=0.05)
    for i in 1:length(genes)
        gene = genes[i]
        cur_weights = adjacent_weights[i]
        cur_points = adjacent_points[i]

        assignment_probs[:, i] .= 0.0
        dense_sum = 0.0
        for j in 1:length(cur_points)
            for ri in 1:size(assignment_probs, 1)
                c_d = cur_weights[j] * assignment_probs[ri, cur_points[j]] * cell_type_exprs[ri, gene]
                assignment_probs[ri, i] += c_d
                dense_sum += c_d
            end
        end

        for ri in 1:size(assignment_probs, 1)
            assignment_probs[ri, i] = (1 - new_prob) * assignment_probs[ri, i] / dense_sum + new_prob * cell_type_exprs_norm[ri, gene]
        end
    end
end

function filter_correlated_clusters!(cell_type_exprs::Matrix{Float64}, assignment::Vector{Int}; correlation_threshold::Float64=0.95)
    cors = cor(cell_type_exprs');
    cors[diagind(cors)] .= 0
    triu!(cors);
    max_cor_ids = vec(mapslices(findmax, cors, dims=1));

    was_filtering = false
    for i1 in 1:length(max_cor_ids)
        c, i2 = max_cor_ids[i1]
        if c < correlation_threshold
            continue
        end

        was_filtering = true
        cell_type_exprs[i1, :] .= 0
        assignment[assignment .== i1] .= i2
    end

    return was_filtering
end

function remove_unused_clusters!(assignment::Vector{Int}, cell_type_exprs::Matrix{Float64}, genes::Vector{Int}; min_mols_per_type)
    n_mols_per_type = count_array(assignment)
    real_type_ids = findall(n_mols_per_type .>= min_mols_per_type)
    if length(real_type_ids) == length(n_mols_per_type)
        return cell_type_exprs
    end

    id_map = zeros(Int, size(cell_type_exprs, 1))
    id_map[real_type_ids] .= 1:length(real_type_ids)

    cell_type_exprs = cell_type_exprs[real_type_ids,:]

    cell_type_exprs_norm = cell_type_exprs ./ sum(cell_type_exprs, dims=2)
    for i in 1:length(assignment)
        if n_mols_per_type[assignment[i]] < min_mols_per_type
            assignment[i] = findmax(cell_type_exprs_norm[:, genes[i]])[2]
        else
            assignment[i] = id_map[assignment[i]]
        end
    end

    return cell_type_exprs
end

@inline function estimate_difference_l0(m1::Matrix{Float64}, m2::Matrix{Float64})::Float64
    max_diff = 0.0
    if !all(size(m1) .== size(m2))
        error("Matrices must be of the same size")
    end

    @inbounds for ci in 1:size(m1, 2)
        for ri in 1:size(m1, 1)
            max_diff = fmax(abs(m1[ri, ci] - m2[ri, ci]), max_diff)
        end
    end

    return max_diff
end

# TODO: rename
# In case of unknown number of clusters, this function must be ran twice with filter and remove inbetween
function optimize_mols(genes::Vector{Int}, adjacent_points::Vector{Vector{Int}}, adjacent_weights::Vector{Vector{Float64}};
        k::Int=1, max_iters::Int=1000, new_prob::Float64=0.05, tol::Float64=0.01, do_maximize::Bool=true,
        # mrf_prior_weight::Float64=1.0, # this parameter doesn't seem to play role
        cell_type_exprs::Union{Matrix{Float64}, Nothing}=nothing, verbose::Bool=true, progress::Union{Progress, Nothing}=nothing)
    # adjacent_weights = [exp.(aw .* mrf_prior_weight) for aw in adjacent_weights] # It's required to turn problem into classic MRF, but it doesn't affect result

    if cell_type_exprs === nothing
        if k <= 1
            error("Either k or cell_type_exprs must be specified")
        end

        cell_type_exprs = copy(hcat(prob_array.(split(genes, rand(1:k, length(genes))), max_value=maximum(genes))...)')
    end

    cell_type_exprs_norm = cell_type_exprs ./ sum(cell_type_exprs, dims=2)
    cell_type_exprs = (cell_type_exprs .+ 1) ./ (sum(cell_type_exprs, dims=2) .+ 1)

    assignment_probs = cell_type_exprs_norm[:, genes];
    assignment_probs_prev = deepcopy(assignment_probs)
    max_diffs = Float64[]

    if verbose && progress === nothing
        progress = Progress(max_iters, 0.3)
    end

    n_iters = 0
    for i in 1:max_iters
        n_iters = i
        assignment_probs_prev .= assignment_probs
        expect_mols!(assignment_probs, cell_type_exprs, cell_type_exprs_norm, genes, adjacent_points, adjacent_weights, new_prob=new_prob)
        if do_maximize
            maximize_mols!(cell_type_exprs, cell_type_exprs_norm, genes, assignment_probs)
        end

        push!(max_diffs, estimate_difference_l0(assignment_probs, assignment_probs_prev))
        if verbose
            next!(progress)
        end

        if max_diffs[end] < tol
            finish!(progress)
            break
        end
    end

    if verbose
        println("Algorithm stopped after $n_iters iterations. Error: $(round(max_diffs[end], sigdigits=3)). Converged: $(max_diffs[end] <= tol).")
    end

    if do_maximize
        maximize_mols!(cell_type_exprs, cell_type_exprs_norm, genes, assignment_probs)
    end

    assignment = vec(mapslices(x -> findmax(x)[2], assignment_probs, dims=1));

    return cell_type_exprs_norm, assignment, max_diffs, assignment_probs
end

function build_molecule_graph(df_spatial::DataFrame; kwargs...)
    edge_list, adjacent_dists = adjacency_list(df_spatial; kwargs...);

    real_edge_length = quantile(adjacent_dists, 0.3);
    adjacent_weights = real_edge_length ./ max.(adjacent_dists, real_edge_length);

    return convert_edge_list_to_adj_list(edge_list, adjacent_weights; n_verts=size(df_spatial, 1));
end
