"""
ParameterizedModel(td_batch::Vector{<:TruthData}, Δt; N_ens = 50, kwargs...)

Build a `ParameterizedModel` container for an Oceananigans `HydrostaticFreeSurfaceModel` with 
many independent columns. The model grid is given by the data in `td_batch`, and the
dynamics in each column is attached to its own `CATKEVerticalDiffusivity` closure stored in 
an `(Nx, Ny)` Matrix of closures. `Δt` is the model time step, `N_ens = 50` is the 
desired count of ensemble members for calibration with Ensemble Kalman Inversion (EKI), and the 
remaining keyword arguments `kwargs` define the default closure across all columns.

In the "many columns" configuration, we run the model on a 3D grid with `(Flat, Flat, Bounded)` boundary 
conditions so that many independent columns can be evolved at once with much of the computational overhead
split among the columns. The `Nx` rows of vertical columns are each reserved for an "ensemble" member
whose attached parameter value (updated at each iteration of EKI) sets the diffusivity closure
used to predict the model solution for the `Ny` physical scenarios described by the simulation-specific 
`TruthData` objects in `td_batch`.
"""
function ParameterizedModel(td_batch::Vector{<:TruthData}, Δt; N_ens = 50, kwargs...)

    grid = td_batch[1].grid
    closure = [CATKEVerticalDiffusivity(Float64; warning=false, kwargs...) for i=1:N_ens, j=1:length(td_batch)]

    # coriolis = [td.constants[:f] for i=1:N_ens, td in td_batch]
    coriolis = td_batch[1].constants[:f]

    bc_matrix(f) = [f(td.boundary_conditions) for i = 1:N_ens, td in td_batch]
    Qᵇ = bc_matrix(bc -> bc.Qᵇ)
    Qᵘ = bc_matrix(bc -> bc.Qᵘ)
    Qᵛ = bc_matrix(bc -> bc.Qᵛ)
    dbdz_bottom = bc_matrix(bc -> bc.dbdz_bottom)
    dudz_bottom = bc_matrix(bc -> bc.dudz_bottom)

    u_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵘ), 
                                 bottom = GradientBoundaryCondition(dudz_bottom))
    v_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵛ))
    b_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵇ), 
                                 bottom = GradientBoundaryCondition(dbdz_bottom))

    model = HydrostaticFreeSurfaceModel(grid = grid,
                                         tracers = (:b, :e),
                                         buoyancy = BuoyancyTracer(),
                                         coriolis = FPlane(f=coriolis),
                                         boundary_conditions = (b=b_bcs, u=u_bcs, v=v_bcs),
                                         closure = closure)

    return ParameterizedModel(model, Δt)
end