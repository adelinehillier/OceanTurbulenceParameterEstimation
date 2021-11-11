# # Perfect convective adjustment calibration with Ensemble Kalman Inversion
#
# This example showcases a "perfect model calibration" of the convective adjustement problem. We use
# output for buoyancy (``b``) to calibrate the convective adjustment closure and recover the 
# background and the convective diffusivities used to create some synthetic data.
#
# The calibration is done here using Ensemble Kalman Inversion. For more information about the 
# algorithm refer to [EnsembleKalmanProcesses.jl documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).

# ## Install dependencies
#
# First let's make sure we have all required packages installed.

# ```julia
# using Pkg
# pkg"add OceanTurbulenceParameterEstimation, Oceananigans, Distributions, CairoMakie"
# ```

using OceanTurbulenceParameterEstimation, LinearAlgebra, CairoMakie

# We reuse some some code from a previous example to generate observations,
@show examples_path = joinpath(pathof(OceanTurbulenceParameterEstimation), "..", "..", "examples")
include(joinpath(examples_path, "intro_to_inverse_problems.jl"))

data_path = generate_free_convection_synthetic_observations()
observations = OneDimensionalTimeSeries(data_path, field_names=:b, normalize=ZScore)

# and an ensemble_simulation,

ensemble_simulation, θ★ = build_ensemble_simulation(observations; Nensemble=50)

# The handy utility function `build_ensemble_simulation` also tells us the optimal
# parameters that were used when generating the synthetic observations:

@show θ★

# Here, we'll attempt to calibrate `convective_κz` and `background_κz`.

# # The `InverseProblem`
#
# The `InverseProblem` defines the `observations`, `ensemble_simulation`, and
# `free_parameters` to be calibrated. Specifying `free_parameters` determines
# their names and prior distributions:

priors = (convective_κz = lognormal_with_mean_std(0.3, 0.5),
          background_κz = lognormal_with_mean_std(2.5e-4, 0.25e-4))

free_parameters = FreeParameters(priors)

calibration = InverseProblem(observations, ensemble_simulation, free_parameters)

# For more information about the above steps, see [Intro to observations](@ref)
# and [Intro to `InverseProblem`](@ref).

# # Ensemble Kalman Inversion
#
# Next, we construct an `EnsembleKalmanInversion` (EKI) object,
#
# The calibration is done here using Ensemble Kalman Inversion. For more information about the 
# algorithm refer to
# [EnsembleKalmanProcesses.jl documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).

noise_variance = observation_map_variance_across_time(calibration)[1, :, 1] .+ 1e-5

eki = EnsembleKalmanInversion(calibration; noise_covariance = Matrix(Diagonal(noise_variance)))

# and perform few iterations to see if we can converge to the true parameter values.

params = iterate!(eki; iterations = 10)

# Last, we visualize the outputs of EKI calibration.

θ̅(iteration) = [eki.iteration_summaries[iteration].ensemble_mean...]
varθ(iteration) = eki.iteration_summaries[iteration].ensemble_variance

weight_distances = [norm(θ̅(iter) - [θ★[1], θ★[2]]) for iter in 1:eki.iteration]
output_distances = [norm(forward_map(calibration, θ̅(iter))[:, 1] - y) for iter in 1:eki.iteration]
ensemble_variances = [varθ(iter) for iter in 1:eki.iteration]

f = Figure()
lines(f[1, 1], 1:eki.iteration, weight_distances, color = :red,
      axis = (title = "Parameter distance",
              xlabel = "Iteration",
              ylabel = "|θ̅ₙ - θ⋆|",
              yscale = log10))
lines(f[1, 2], 1:eki.iteration, output_distances, color = :blue,
      axis = (title = "Output distance",
              xlabel = "Iteration",
              ylabel="|G(θ̅ₙ) - y|",
              yscale = log10))
ax3 = Axis(f[2, 1:2],
           title = "Parameter convergence",
           xlabel = "Iteration",
           ylabel = "Ensemble variance",
           yscale = log10)

for (i, pname) in enumerate(free_parameters.names)
    ev = getindex.(ensemble_variances, i)
    lines!(ax3, 1:eki.iteration, ev / ev[1], label=String(pname))
end

axislegend(ax3, position = :rt)

save("summary_convective_adjustment_eki.svg", f); nothing #hide

# ![](summary_convective_adjustment_eki.svg)

# And also we plot the the distributions of the various model ensembles for few EKI iterations to see
# if and how well they converge to the true diffusivity values.

f = Figure()

axtop = Axis(f[1, 1])
axmain = Axis(f[2, 1],
              xlabel = "convective_κz [m² s⁻¹]",
              ylabel = "background_κz [m² s⁻¹]")

axright = Axis(f[2, 2])
scatters = []

for i in [1, 2, 3, 11]
    ensemble = transpose(eki.iteration_summaries[i].parameters)
    push!(scatters, scatter!(axmain, ensemble))
    density!(axtop, ensemble[:, 1])
    density!(axright, ensemble[:, 2], direction = :y)
end

vlines!(axmain, [θ★.convective_κz], color=:red)
vlines!(axtop, [θ★.convective_κz], color=:red)

hlines!(axmain, [θ★.background_κz], color=:red)
hlines!(axright, [θ★.background_κz], color=:red)

colsize!(f.layout, 1, Fixed(300))
colsize!(f.layout, 2, Fixed(200))
rowsize!(f.layout, 1, Fixed(200))
rowsize!(f.layout, 2, Fixed(300))

Legend(f[1, 2], scatters, ["Initial ensemble", "Iteration 1", "Iteration 2", "Iteration 10"],
       position = :lb)

hidedecorations!(axtop, grid = false)
hidedecorations!(axright, grid = false)

xlims!(axmain, -0.25, 3.2)
xlims!(axtop, -0.25, 3.2)
ylims!(axmain, 5e-5, 35e-5)
ylims!(axright, 5e-5, 35e-5)

save("distributions_convective_adjustment_eki.svg", f); nothing #hide

# ![](distributions_convective_adjustment_eki.svg)
