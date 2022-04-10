module PseudoSteppingSchemes

export adaptive_step_parameters

using LineSearches, Statistics, LinearAlgebra, Distributions
using ..EnsembleKalmanInversions: step_parameters
using ParameterEstimocean.Transformations: ZScore, normalize!

import ..EnsembleKalmanInversions: adaptive_step_parameters

export Constant, Default, GPLineSearch, Chada2021, ConstantConvergence, Kovachki2018

# Default pseudo_stepping::Nothing --- it's not adaptive
eki_update(::Nothing, Xₙ, Gₙ, eki, Δtₙ) = eki_update(Constant(Δtₙ), Xₙ, Gₙ, eki)

eki_update(pseudo_scheme, Xₙ, Gₙ, eki, Δtₙ) = eki_update(pseudo_scheme, Xₙ, Gₙ, eki)

function adaptive_step_parameters(pseudo_scheme, Xₙ, Gₙ, eki; Δt=1.0, 
                                    covariance_inflation = 1.0,
                                    momentum_parameter = 0.0)

    # X is [N_par × N_ens]
    X̅ = mean(Xₙ, dims=2) # [1 × N_ens]

    Xₙ₊₁, Δtₙ = eki_update(pseudo_scheme, Xₙ, Gₙ, eki, Δt)

    # Apply momentum Xₙ ← Xₙ + λ(Xₙ - Xₙ₋₁)
    @. Xₙ₊₁ = Xₙ₊₁ + momentum_parameter * (Xₙ₊₁ - Xₙ)

    # Apply covariance inflation
    @. Xₙ₊₁ = Xₙ₊₁ + (Xₙ₊₁ - X̅) * covariance_inflation

    return Xₙ₊₁, Δtₙ

end

function iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ=1.0)

    N_obs, N_ens = size(Gₙ)

    y = eki.mapped_observations
    Γy = eki.noise_covariance

    # Scale noise Γy using Δt. 
    Δt⁻¹Γy = Γy / Δtₙ

    ξₙ = rand(MvNormal(zeros(N_obs), Δt⁻¹Γy), N_ens)

    Cᶿᵍ = cov(Xₙ, Gₙ, dims = 2, corrected = false) # [N_par × N_obs]
    Cᵍᵍ = cov(Gₙ, Gₙ, dims = 2, corrected = false) # [N_obs × N_obs]

    y_perturbed = y .+ ξₙ # [N_obs x N_ens]

    # EKI update: θ ← θ + Cᶿᵍ(Cᵍᵍ + h⁻¹Γy)⁻¹(y + ξₙ - g)
    tmp = (Cᵍᵍ + Δt⁻¹Γy) \ (y_perturbed - Gₙ) # [N_obs × N_ens]
    Xₙ₊₁ = Xₙ + (Cᶿᵍ * tmp) # [N_par × N_ens]

    return Xₙ₊₁
end

frobenius_norm(A) = sqrt(sum(A .^ 2))

function kovachki_2018_update(Xₙ, Gₙ, eki; Δt₀=1.0)

    y = eki.mapped_observations
    Γy = eki.noise_covariance
    
    N_ens = size(Xₙ, 2)
    g̅ = mean(G, dims = 2)
    Γy⁻¹ = inv(Γy)

    # Compute flattened ensemble u = [θ⁽¹⁾, θ⁽²⁾, ..., θ⁽ᴶ⁾]
    uₙ = vcat([Xₙ[:,j] for j in 1:N_ens]...)

    # Fill transformation matrix (D(uₙ))ᵢⱼ = ⟨ G(u⁽ⁱ⁾) - g̅, Γy⁻¹(G(u⁽ʲ⁾) - y) ⟩
    for j = 1:N_ens, i = 1:N_ens
        D[i, j] = dot(Gₙ[:, i] - g̅, Γy⁻¹ * (Gₙ[:, j] - y))
    end

    # Calculate time step Δtₙ₋₁ = Δt₀ / (frobenius_norm(D(uₙ)) + ϵ)
    Δtₙ = Δt₀ / (frobenius_norm(D) + 1e-10)

    # Update uₙ₊₁ = uₙ - Δtₙ₋₁ D(uₙ) uₙ
    uₙ₊₁ = uₙ - Δtₙ * D * uₙ
    Xₙ₊₁ = reshape(uₙ₊₁, size(Xₙ))

    return Xₙ₊₁
end

###
### Fixed and adaptive time stepping schemes
###

abstract type AbstractSteppingScheme end

struct Constant{S} <: AbstractSteppingScheme
    step_size :: S
end

Constant(; step_size=1.0) = Constant(step_size)

struct Default{C} <: AbstractSteppingScheme 
    cov_threshold :: C
end

Default(; cov_threshold=0.01) = Default(cov_threshold)

struct GPLineSearch{L} <: AbstractSteppingScheme
    learning_rate :: L
end

GPLineSearch(; learning_rate=1e-4) = GPLineSearch(learning_rate)

struct Chada2021{I, B} <: AbstractSteppingScheme
    initial_step_size :: I
    β                 :: B
end

Chada2021(; initial_step_size=1.0, β=0.0) = Chada2021(initial_step_size, β)

"""
    ConstantConvergence{T} <: AbstractSteppingScheme
    
- `convergence_ratio` (`Number`): The convergence rate for the EKI adaptive time stepping. Default value 0.7.
                                 If a numerical value is given is 0.7 which implies that the parameter spread 
                                 covariance is decreased to 70% of the parameter spread covariance at the previous
                                 EKI iteration.
"""
struct ConstantConvergence{T} <: AbstractSteppingScheme
    convergence_ratio :: T
end

ConstantConvergence(; convergence_ratio=0.7) = ConstantConvergence(convergence_ratio)

struct Kovachki2018{T} <: AbstractSteppingScheme
    initial_step_size :: T
end

Kovachki2018(; initial_step_size=1.0) = Kovachki2018(initial_step_size)

function eki_update(pseudo_scheme::Constant, Xₙ, Gₙ, eki)

    Δtₙ = pseudo_scheme.step_size
    Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)

    return Xₙ₊₁, Δtₙ
end

function eki_update(pseudo_scheme::Kovachki2018, Xₙ, Gₙ, eki)

    initial_step_size = pseudo_scheme.initial_step_size
    Xₙ₊₁ = kovachki_2018_update(Xₙ, Gₙ, eki; Δt₀=1.0)

    return Xₙ₊₁, Δtₙ
end

function eki_update(pseudo_scheme::Chada2021, Xₙ, Gₙ, eki)

    initial_step_size = pseudo_scheme.initial_step_size
    Δtₙ = (n ^ pseudo_scheme.β) * initial_step_size
    Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)

    return Xₙ₊₁, Δtₙ
end

function eki_update(pseudo_scheme::Default, Xₙ, Gₙ, eki)

    Δtₙ₋₁ = eki.pseudo_Δt

    accept_stepsize = false
    Δtₙ = copy(Δtₙ₋₁)

    cov_init = cov(Xₙ, dims = 2)

    while !accept_stepsize

        Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)

        cov_new = cov(Xₙ₊₁, dims = 2)
        if det(cov_new) > pseudo_scheme.cov_threshold * det(cov_init)
            accept_stepsize = true
        else
            Δtₙ = Δtₙ / 2
        end
    end

    Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)

    return Xₙ₊₁, Δtₙ
end

"""
    collapse_ensemble(eki, iteration)

Returns an `N_params x N_ensemble` array of parameter values for a given iteration `iteration`.
"""
function ensemble_array(eki, iteration)
    ensemble = eki.iteration_summaries[iteration].parameters
    param_names = keys(first(ensemble))

    N_params = length(param_names)
    N_ensemble = length(ensemble)

    ensemble_array = zeros(N_params, N_ensemble)
    for (i, param_name) in enumerate(param_names)
        view(ensemble_array, i, :) .= getproperty.(ensemble, param_name)
    end

    return ensemble_array
end

function trained_gp_predict_function(X, y)

    N_param = size(X, 1)

    zscore = ZScore(mean(y), var(y))
    normalize!(y, zscore)

    # log- length scale kernel parameter
    ll = [0.0 for _ in N_param]
    # log- noise kernel parameter
    lσ = 0.0

    kern = Matern(5/2, ll, lσ)
    mZero = MeanZero()
    gp = GP(X, y, mZero, kern, -2.0)

    # Use LBFGS to optimize kernel parameters
    optimize!(gp)

    function predict(X) 
        ŷ = predict_f(gp, X)[1]
        inverse_normalize!(ŷ, zscore)
        return ŷ
    end

    return predict
end

function eki_update(pseudo_scheme::GPLineSearch, Xₙ, Gₙ, eki)
    
    # ensemble covariance
    Cᶿᶿ = cov(Xₙ, dims = 2)

    n = length(eki.iteration_summaries) - 1 # (initial state doesn't count)

    Xₙ = ensemble_array(eki, n)
    Xₙ₋₁ = ensemble_array(eki, n-1)

    # approximate time derivatives of the particles
    # looking backward. size N_param x N_ensemble
    Ẋ_backward = Xₙ - Xₙ₋₁

    # In the continuous-time limit assuming locally linear G,
    # the EKI dynamic for each individual particle θ
    # becomes a preconditioned gradient descent
    # θ̇ = - Cᶿᶿ ∇Φ(θ), where Φ is the EKI objective
    approx_∇Φ = - Cᶿᶿ \ Ẋ_backward

    Xₙ₊₁_test = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ=1.0)

    Ẋ_forward = Xₙ₊₁_test - Xₙ

    ls = BackTracking(c_1 = pseudo_scheme.learning_rate)

    # X is all samples generated thus far
    X = hcat([ensemble_array(eki, iter) for iter in 0:n]...) 
    y = vcat([sum.(eki.iteration_summaries[iter].objective_values) for iter in 0:n]...)

    not_nan_indices = findall(.!isnan.(y))
    X = X[:, not_nan_indices]
    y = y[not_nan_indices]
    
    predict = trained_gp_predict_function(X, y)

    αs = []
    αinitial = 1.0

    for j = 1:N_ensemble

        xʲ = Xₙ[:, j]

        # search direction looking forward
        # Gʲ = G[:, j]
        # s .= - (1/N_ensemble) .* sum( [dot(G[:, k] - g̅, Γy⁻¹ * (Gʲ - y)) .* Xₙ[:, k] for k = 1:N_ensemble] )
        s = Ẋ_forward[:, j]
        
        ϕ(α) = predict(xʲ .+ α .* s)

        # gradient w.r.t. linesearch step size parameter α
        # (equivalent to directional derivative in the search direction, s)
        dϕ_0 = dot(s, approx_∇Φ[:, j])

        ϕ_0 = sum(eki.iteration_summaries[end].objective_values[j])
        
        # For general linesearch, arguments are (ϕ, dϕ, ϕdϕ, α0, ϕ0,dϕ0)
        α, _ = ls(ϕ, αinitial, ϕ_0, dϕ_0)

        push!(αs, α)
    end

    Δtₙ = mean(αs)

    Xₙ₊₁ = Xₙ + Δtₙ * s
    
    return Xₙ₊₁, Δtₙ

end

function volume_ratio(Xₙ₊₁, Xₙ)
    Vⁿ⁺¹ = det(cov(Xₙ₊₁, dims=2))
    Vⁿ   = det(cov(Xₙ,   dims=2))
    return Vⁿ⁺¹ / Vⁿ
end

function eki_update(pseudo_scheme::ConstantConvergence, Xₙ, Gₙ, eki)

    conv_rate = pseudo_scheme.convergence_ratio

    # Test step forward
    Δtₙ = 1.0
    Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)
    r = volume_ratio(Xₙ₊₁, Xₙ)

    # "Accelerated" fixed point iteration to adjust step_size
    p = 1.1
    iter = 1
    while !isapprox(r, conv_rate, atol=0.03, rtol=0.1) && iter < 10
        Δtₙ *= (r / conv_rate)^p
        Xₙ₊₁ = iglesias_2013_update(Xₙ, Gₙ, eki; Δtₙ)
        r = volume_ratio(Xₙ₊₁, Xₙ)
        iter += 1
    end

    @info "Particles stepped adaptively with convergence rate $r (target $conv_rate)"

    return Xₙ₊₁, Δtₙ
end

end # module