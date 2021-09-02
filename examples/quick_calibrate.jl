pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "projects", "OceanBoundaryLayerParameterizations", "src"))

using OceanTurbulenceParameterEstimation
using OceanTurbulenceParameterEstimation.ModelsAndData
using OceanTurbulenceParameterEstimation.ParameterEstimation
using OceanTurbulenceParameterEstimation.LossFunctions
using OceanTurbulenceParameterEstimation.CATKEVerticalDiffusivityModel

using OceanBoundaryLayerParameterizations

# CATKE parameters involved in setting field diffusivities 
StabilityFnParameters = @free_parameters CᴷRiʷ, CᴷRiᶜ, Cᴷu⁻, Cᴷuʳ, Cᴷc⁻, Cᴷcʳ, Cᴷe⁻, Cᴷeʳ,

parameters = Parameters(
    RelevantParameters = CATKEParametersRiDependent,  # Parameters that are used in CATKE
    ParametersToOptimize = StabilityFnParameters    # Subset of RelevantParameters that we want to optimize
)

# DataSet represents the Model, Data, and loss function
#
# Other names might be
#
# - ModelDataComparison
# calibrate(::ModelDataComparison)
# validate(::ModelDataComparison)
calibration = DataSet(FourDaySuite, # "Truth data" for model calibration
                      parameters;   # Model parameters 
                      # Loss function parameters
                      relative_weights = relative_weight_options["all_but_e"],
                      # Model (hyper)parameters
                      ensemble_size = 10,
                      Nz = 16,
                      Δt = 30.0)

validation = DataSet(merge(TwoDaySuite, SixDaySuite), p;
                     relative_weights = relative_weight_options["all_but_e"],
                     ensemble_size = 10,
                     Nz = 64,
                     Δt = 10.0);

# Loss on default parameters
l0 = calibration()

# Loss on parameters θ.
# θ can be 
#   1. a vector
#   2. a FreeParameters object
#   3. a vector of parameter vectors (one for each ensemble member)
#   4. or a vector of FreeParameter objects (one for each ensemble member)
# If (1) or (2), the ensemble members are redundant and the loss is computed for just the one parameter set.
lθ = calibration(θ)

# Output files/figures
directory = joinpath(pwd(), "quick_calibrate_results")

# Example parameters
θ = calibration.default_parameters

# Run the model forward and store the solution
output = model_time_series(calibration, θ)

# Run the model forward with parameters θ and visualize the solution compared to the truth
visualize_realizations(calibration, θ; filename = "example_quick_calibrate.png")

# Runs `visualize_realizations` and records a summary of the calibration results in a `result.txt` file.
visualize_and_save(calibration, validation, default_parameters, directory)

# Use EKI to calibrate a one-dimensional loss function
eki(loss::DataSet, initial_parameters;
                   noise_level = 10^(-2.0),
                   N_ens = 10,
                   N_iter = 15,
                   stds_within_bounds = 0.6,
                   informed_priors = false,
                   objective_scale_info = false)

plot_prior_variance_and_obs_noise_level(calibration, validation, initial_parameters, directory; vrange=0.40:0.025:0.90, nlrange=-2.5:0.1:0.5)
