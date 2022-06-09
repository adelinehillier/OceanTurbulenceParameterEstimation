module EnsembleKalmanInversions

export
    iterate!,
    EnsembleKalmanInversion,
    Resampler,
    FullEnsembleDistribution,
    NormExceedsMedian,
    SuccessfulEnsembleDistribution

using OffsetArrays
using ProgressBars
using Random
using Printf
using LinearAlgebra
using Statistics
using Distributions
using EnsembleKalmanProcesses:
    get_u_final,
    Inversion,
    Sampler,
    update_ensemble!,
    EnsembleKalmanProcess

using ..Parameters: unconstrained_prior, transform_to_constrained, inverse_covariance_transform
using ..InverseProblems: Nensemble, observation_map, forward_map, tupify_parameters
using ..InverseProblems: inverting_forward_map

using Oceananigans.Utils: prettytime

mutable struct EnsembleKalmanInversion{E, I, M, O, S, R, X, G, C, F}
    inverse_problem :: I
    ensemble_kalman_process :: E
    mapped_observations :: M
    noise_covariance :: O
    iteration :: Int
    pseudotime :: Float64
    pseudo_Δt :: Float64
    iteration_summaries :: S
    resampler :: R
    unconstrained_parameters :: X
    forward_map_output :: G
    pseudo_stepping :: C
    mark_failed_particles :: F
end

Base.show(io::IO, eki::EnsembleKalmanInversion) =
    print(io, "EnsembleKalmanInversion", '\n',
              "├── inverse_problem: ", summary(eki.inverse_problem), '\n',
              "├── ensemble_kalman_process: ", summary(eki.ensemble_kalman_process), '\n',
              "├── mapped_observations: ", summary(eki.mapped_observations), '\n',
              "├── noise_covariance: ", summary(eki.noise_covariance), '\n',
              "├── pseudo_stepping: $(eki.pseudo_stepping)", '\n',
              "├── iteration: $(eki.iteration)", '\n',
              "├── resampler: $(summary(eki.resampler))",
              "├── unconstrained_parameters: $(summary(eki.unconstrained_parameters))", '\n',
              "├── forward_map_output: $(summary(eki.forward_map_output))", '\n',
              "└── mark_failed_particles: $(summary(eki.mark_failed_particles))")

construct_noise_covariance(noise_covariance::AbstractMatrix, y) = noise_covariance

function construct_noise_covariance(noise_covariance::Number, y)
    η = convert(eltype(y), noise_covariance)
    Nobs = length(y)
    return Matrix(η * I, Nobs, Nobs)
end

"""
    EnsembleKalmanInversion(inverse_problem;
                            noise_covariance = 1,
                            pseudo_stepping = nothing,
                            resampler = Resampler(),
                            unconstrained_parameters = nothing,
                            forward_map_output = nothing,
                            mark_failed_particles = NormExceedsMedian(1e9),
                            ensemble_kalman_process = Inversion())

Return an object that finds local minima of the inverse problem:

```math
y = G(θ) + η,
```

for the parameters ``θ``, where ``y`` is a vector of observations (often normalized),
``G(θ)`` is a forward map that predicts the observations, and ``η ∼ 𝒩(0, Γ_y)`` is zero-mean
random noise with a `noise_covariance` matrix ``Γ_y`` representing uncertainty in the observations.

The "forward map output" `G` is model output mapped to the space of `inverse_problem.observations`.

(For more details on the Ensemble Kalman Inversion algorithm refer to the
[EnsembleKalmanProcesses.jl Documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).)

Positional Arguments
====================

- `inverse_problem` (`InverseProblem`): Represents an inverse problem representing the comparison between
                                        synthetic observations generated by
                                        [Oceananigans.jl](https://clima.github.io/OceananigansDocumentation/stable/)
                                        and model predictions, also generated by Oceananigans.jl.

Keyword Arguments
=================
- `noise_covariance` (`Number` or `AbstractMatrix`): Covariance matrix representing observational uncertainty.
                                                     `noise_covariance::Number` is converted to a scaled identity matrix.

- `pseudo_stepping`: The pseudo time-stepping scheme for stepping EKI forward.

- `resampler`: controls particle resampling procedure. See `Resampler`.

- `unconstrained_parameters`: Default: `nothing`.

- `forward_map_output`: Default: `nothing`.

- `ensemble_kalman_process`: Process type defined by `EnsembleKalmanProcesses.jl`.
                             Default: `Inversion()`.
"""
function EnsembleKalmanInversion(inverse_problem;
                                 noise_covariance = 1,
                                 pseudo_stepping = nothing,
                                 pseudo_Δt = 1.0,
                                 resampler = Resampler(),
                                 unconstrained_parameters = nothing,
                                 forward_map_output = nothing,
                                 mark_failed_particles = NormExceedsMedian(1e9),
                                 ensemble_kalman_process = Inversion())

    if ensemble_kalman_process isa Sampler && !isnothing(pseudo_stepping)
        @warn "Process is $ensemble_kalman_process; ignoring keyword argument pseudo_stepping=$pseudo_stepping."
        pseudo_stepping = nothing
    end

    if isnothing(unconstrained_parameters)
        isnothing(forward_map_output) ||
            throw(ArgumentError("Cannot provide forward_map_output without unconstrained_parameters."))

        free_parameters = inverse_problem.free_parameters
        priors = free_parameters.priors
        Nθ = length(priors)
        Nens = Nensemble(inverse_problem)

        # Generate an initial sample of parameters
        unconstrained_priors = NamedTuple(name => unconstrained_prior(priors[name])
                                          for name in free_parameters.names)

        unconstrained_parameters = [rand(unconstrained_priors[i]) for i=1:Nθ, k=1:Nens]
    end

    # Build EKP-friendly observations "y" and the covariance matrix of observational uncertainty "Γy"
    y = dropdims(observation_map(inverse_problem), dims=2) # length(forward_map_output) column vector
    Γy = construct_noise_covariance(noise_covariance, y) # noise_covariance * UniformScaling(1.0)
    Xᵢ = unconstrained_parameters
    iteration = 0
    pseudotime = 0.0

    eki′ = EnsembleKalmanInversion(inverse_problem,
                                   ensemble_kalman_process,
                                   y,
                                   Γy,
                                   iteration,
                                   pseudotime,
                                   pseudo_Δt,
                                   nothing,
                                   resampler,
                                   Xᵢ,
                                   forward_map_output,
                                   pseudo_stepping,
                                   mark_failed_particles)

    if isnothing(forward_map_output) # execute forward map to generate initial summary and forward_map_output
        @info "Executing forward map while building EnsembleKalmanInversion..."
        start_time = time_ns()
        forward_map_output = resampling_forward_map!(eki′, Xᵢ)
        elapsed_time = (time_ns() - start_time) * 1e-9
        @info "    ... done ($(prettytime(elapsed_time)))."
    end

    summary = IterationSummary(eki′, Xᵢ, forward_map_output)
    iteration_summaries = OffsetArray([summary], -1)

    eki = EnsembleKalmanInversion(inverse_problem,
                                  eki′.ensemble_kalman_process,
                                  eki′.mapped_observations,
                                  eki′.noise_covariance,
                                  iteration,
                                  pseudotime,
                                  pseudo_Δt,
                                  iteration_summaries,
                                  eki′.resampler,
                                  eki′.unconstrained_parameters,
                                  forward_map_output,
                                  eki′.pseudo_stepping,
                                  eki′.mark_failed_particles)
    
    return eki
end

include("iteration_summary.jl")
include("resampling.jl")

#####
##### Iterating
#####

function resampling_forward_map!(eki, X=eki.unconstrained_parameters)
    G = inverting_forward_map(eki.inverse_problem, X) # (len(G), Nensemble)
    resample!(eki.resampler, X, G, eki)
    return G
end

"""
    iterate!(eki::EnsembleKalmanInversion;
             iterations = 1,
             pseudo_Δt = eki.pseudo_Δt,
             pseudo_stepping = eki.pseudo_stepping,
             show_progress = true)

Iterate the ensemble Kalman inversion problem `eki` forward by `iterations`.

Keyword arguments
=================

- `iterations` (`Int`): Number of iterations to run. (Default: 1)

- `pseudo_Δt` (`Float64`): Pseudo time-step. When `convegence_rate` is specified,
                           this is an initial guess for finding an adaptive time-step.
                           (Default: `eki.pseudo_Δt`)

- `pseudo_stepping` (`Float64`): Ensemble convergence rate for adaptive time-stepping.
                                 (Default: `eki.pseudo_stepping`)

- `show_progress` (`Boolean`): Whether to show a progress bar. (Default: `true`)

Return
======

- `best_parameters`: the ensemble mean of all parameter values after the last iteration.
"""
function iterate!(eki::EnsembleKalmanInversion;
                  iterations = 1,
                  pseudo_Δt = eki.pseudo_Δt,
                  pseudo_stepping = eki.pseudo_stepping,
                  show_progress = true)

    iterator = show_progress ? ProgressBar(1:iterations) : 1:iterations

    for _ in iterator
        # When stepping adaptively, `Δt` is an initial guess for the
        # actual adaptive step that gets taken.
        eki.unconstrained_parameters, adaptive_Δt = step_parameters(eki, pseudo_stepping; Δt=pseudo_Δt)
                                                                    
        # Update the pseudoclock
        eki.iteration += 1
        eki.pseudotime += adaptive_Δt
        eki.pseudo_Δt = adaptive_Δt

        # Forward map
        eki.forward_map_output = resampling_forward_map!(eki)
        summary = IterationSummary(eki, eki.unconstrained_parameters, eki.forward_map_output)
        push!(eki.iteration_summaries, summary)
    end

    # Return ensemble mean (best guess for optimal parameters)
    best_parameters = eki.iteration_summaries[end].ensemble_mean

    return best_parameters
end

#####
##### Failure condition, stepping, and adaptive stepping
#####

"""
    NormExceedsMedian(minimum_relative_norm = 1e9)

The particle failure condition. A particle is marked "failed" if the forward map norm is
larger than `minimum_relative_norm` times more than the median value of the ensemble.
By default `minimum_relative_norm = 1e9`.
"""
struct NormExceedsMedian{T}
    minimum_relative_norm :: T
    NormExceedsMedian(minimum_relative_norm = 1e9) = 
        minimum_relative_norm < 0 ? error("minimum_relative_norm must non-negative") :
        new{typeof(minimum_relative_norm)}(minimum_relative_norm)
end

""" Return a BitVector indicating whether the norm of the forward map
for a given particle exceeds the median by `mrn.minimum_relative_norm`."""
function (mrn::NormExceedsMedian)(G)
    ϵ = mrn.minimum_relative_norm

    G_norm = mapslices(norm, G, dims=1)
    finite_G_norm = filter(!isnan, G_norm)
    median_norm = median(finite_G_norm)
    failed(column) = any(isnan.(column)) || norm(column) > ϵ * median_norm

    return vec(mapslices(failed, G; dims=1))
end

function step_parameters(X, G, y, Γy, process; Δt=1.0)
    ekp = EnsembleKalmanProcess(X, y, Γy, process; Δt)
    update_ensemble!(ekp, G)
    return get_u_final(ekp)
end

# Default pseudo_stepping::Nothing --- it's not adaptive
adaptive_step_parameters(::Nothing, Xⁿ, Gⁿ, y, Γy, process; Δt) = step_parameters(Xⁿ, Gⁿ, y, Γy, process; Δt), Δt

function step_parameters(eki::EnsembleKalmanInversion, pseudo_stepping; Δt=1.0)
    process = eki.ensemble_kalman_process
    y = eki.mapped_observations
    Γy = eki.noise_covariance
    Gⁿ = eki.forward_map_output
    Xⁿ = eki.unconstrained_parameters
    Xⁿ⁺¹ = similar(Xⁿ)

    # Handle failed particles
    particle_failure = eki.mark_failed_particles(Gⁿ)
    failures = findall(particle_failure) # indices of columns (particles) with `NaN`s
    successes = findall(.!particle_failure)
    some_failures = length(failures) > 0

    some_failures && @warn string(length(failures), " particles failed. ",
                                  "Performing ensemble update with statistics from ",
                                  length(successes), " successful particles.")

    successful_Gⁿ = Gⁿ[:, successes]
    successful_Xⁿ = Xⁿ[:, successes]

    # Construct new parameters
    successful_Xⁿ⁺¹, Δt = adaptive_step_parameters(pseudo_stepping,
                                                   successful_Xⁿ,
                                                   successful_Gⁿ,
                                                   y,
                                                   Γy,
                                                   process;
                                                   Δt)

    Xⁿ⁺¹[:, successes] .= successful_Xⁿ⁺¹

    if some_failures # resample failed particles with new ensemble distribution
        new_X_distribution = ensemble_normal_distribution(successful_Xⁿ⁺¹) 
        sampled_Xⁿ⁺¹ = rand(new_X_distribution, length(failures))
        Xⁿ⁺¹[:, failures] .= sampled_Xⁿ⁺¹
    end

    return Xⁿ⁺¹, Δt
end

end # module
