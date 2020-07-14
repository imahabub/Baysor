using Baysor, Test
using DataFrames
using Statistics
import Random: seed!

B = Baysor

@testset "Baysor" begin
    @testset "utils" begin
        @testset "convex_hull" begin
            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1]])
            @test all(chull .== [0 0 1 1 0; 0 1 1 0 0])
            @test B.area(chull) ≈ 1.0

            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1], [0, 2], [2, 0]])
            @test all(chull .== [0 0 2 0; 0 2 0 0])
            @test B.area(chull) ≈ 2.0

            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1], [0, 2], [2, 0], [2, 2]])
            @test all(chull .== [0 0 2 2 0; 0 2 2 0 0])
            @test B.area(chull) ≈ 4.0
        end

        @testset "utils" begin
            @test all([B.interpolate_linear(x, 0.0, 1.0; y_start=0.0, y_end=1.0) ≈ x for x in range(0, 1.0, length=50)])
        end
    end

    @testset "distributions" begin
        @testset "ShapePrior" begin
            seed!(42)

            means = B.MeanVec([10.0, 20.0])
            std_stds = B.MeanVec([5.0, 10.0])
            stds = hcat([Vector(B.sample_var(B.ShapePrior(means, std_stds, 1000))) for i in 1:100000]...) .^ 0.5
            @test all(stds .> 0)
            @test all(abs.(vec(mean(stds, dims=2)) .- means) .< 1)

            means = B.MeanVec([1000.0, 2000.0])
            stds = hcat([Vector(B.sample_var(B.ShapePrior(means, std_stds, 1000))) for i in 1:100000]...) .^ 0.5
            @test all(stds .> 0)
            @test all(abs.(vec(mean(stds, dims=2)) .- means) .< 1)
            @test all(abs.(vec(std(stds, dims=2)) .- std_stds) .< 1)
        end
    end

    @testset "data_processing" begin
        @testset "initialization" begin
            n_mols = 1000
            df = DataFrame(:x => rand(n_mols), :y => rand(n_mols), :gene => rand(1:10, n_mols))

            for i in 1:10
                bm_data_arr = B.initial_distribution_arr(df, n_frames=i, scale=6.0, min_molecules_per_cell=30);
                @test length(bm_data_arr) <= i
            end

            df[!, :cluster] = rand(1:5, n_mols)
            df[!, :prior_segmentation] = rand(1:100, n_mols)
            bm_data = B.initial_distribution_arr(df, n_frames=1, scale=6.0, min_molecules_per_cell=30)[1];
            @test all(bm_data.cluster_per_molecule .== df.cluster)
            @test all(bm_data.segment_per_molecule .== df.prior_segmentation)

            for i in 5:10:55
                init_params = B.cell_centers_uniformly(df, i; scale=10)
                @test size(init_params.centers, 1) == i
                @test size(init_params.centers, 2) == 2
                @test length(init_params.covs) == i
                @test maximum(init_params.assignment) == i
            end
        end

        @testset "parse_parameters" begin
            @test B.parse_scale_std("23.55%", 121.0) ≈ 121.0 * 0.2355
            @test B.parse_scale_std(33.87, 121.0) ≈ 33.87
            @test B.parse_scale_std(nothing, 121.0) ≈ 121.0 * 0.25
        end

        @testset "molecule_graph" begin
            for adj_type in [:triangulation, :knn, :both]
                adj_points, adj_weights = B.build_molecule_graph(DataFrame(rand(1000, 2), [:x, :y]); adjacency_type=adj_type, k_adj=30)[1:2];
                @test all(length.(adj_points) .== length.(adj_weights))
                @test all(length.(adj_points) .== length.(unique.(adj_points)))
            end
        end
    end

    @testset "bmm_algorithm" begin
        @testset "noise_composition_density" begin
            n_mols = 5000
            for confs in [ones(n_mols), rand(n_mols)]
                df = DataFrame(:x => rand(n_mols), :y => rand(n_mols), :gene => rand(1:10, n_mols), :confidence => confs)
                bm_data = B.initial_distribution_arr(df, n_frames=1, scale=6.0, min_molecules_per_cell=10, confidence_nn_id=0)[1];
                B.maximize!(bm_data)
                dens_exp = mean([mean(c.composition_params.counts[c.composition_params.counts .> 0] ./ c.composition_params.sum_counts) for c in bm_data.components]);
                dens_obs = B.noise_composition_density(bm_data)
                @test abs(dens_exp - dens_obs) < 1e-10
            end
        end
    end
end