mutable struct IMMCTM
    K::Vector{Int}          # topics
    D::Int                  # documents
    N::Vector{Vector{Int}}  # observations per document modality
    M::Int                  # modalities
    I::Vector{Int}          # features per modality
    J::Vector{Vector{Int}}  # values per modality feature
    V::Vector{Int}          # vocab items per modality

    μ::Vector{Float64}
    Σ::Matrix{Float64}
    invΣ::Matrix{Float64}
    α::Vector{Vector{Float64}}

    ζ::Vector{Vector{Float64}}
    θ::Vector{Vector{Matrix{Float64}}}
    λ::Vector{Vector{Float64}}
    ν::Vector{Vector{Float64}}
    γ::Vector{Vector{Vector{Vector{Float64}}}}
    Elnϕ::Vector{Vector{Vector{Vector{Float64}}}}

    features::Vector{Matrix{Int}}
    X::Vector{Vector{Matrix{Int}}}

    converged::Bool
    elbo::Float64
    ll::Vector{Float64}

    function IMMCTM(k::Vector{Int}, α::Vector{Vector{Float64}},
                    features::Vector{Matrix{Int}},
                    X::Vector{Vector{Matrix{Int}}})
        model = new()

        model.K = copy(k)
        model.α = deepcopy(α)
        model.features = deepcopy(features)
        model.X = X

        model.D = length(X)
        model.M = length(features)
        model.I = [size(features[m])[2] for m in 1:model.M]
        model.J = [vec(maximum(features[m], dims=1)) for m in 1:model.M]
        model.V = [size(features[m])[1] for m in 1:model.M]
        model.N = [[sum(X[d][m][:, 2]) for m in 1:model.M] for d in 1:model.D]

        MK = sum(model.K)

        model.μ = zeros(MK)
        model.Σ = Matrix{Float64}(I, MK, MK)
        model.invΣ = Matrix{Float64}(I, MK, MK)

        model.θ = [
            [
                fill(1.0 / model.K[m], model.K[m], size(model.X[d][m])[1])
                for m in 1:model.M
            ] for d in 1:model.D
        ]

        model.γ = [
            [
                [
                    rand(1:100, model.J[m][i]) for i in 1:model.I[m]
                ] for k in 1:model.K[m]
            ] for m in 1:model.M
        ]
        model.Elnϕ = deepcopy(model.γ)
        update_Elnϕ!(model)

        model.λ = [zeros(MK) for d in 1:model.D]
        model.ν = [ones(MK) for d in 1:model.D]

        model.ζ = [Array{Float64}(undef, model.M) for d in 1:model.D]
        for d in 1:model.D update_ζ!(model, d) end

        model.converged = false

        return model
    end
end

function IMMCTM(k::Vector{Int}, α::Vector{Float64},
                features::Vector{Matrix{Int}},
                X::Vector{Vector{Matrix{Int}}})
    M = length(features)
    I = [size(features[m])[2] for m in 1:M]
    full_α = Vector{Float64}[fill(α[m], I[m]) for m in 1:M]
    return IMMCTM(k, full_α, features, X)
end

function calculate_sumθ(model::IMMCTM, d::Int)
    return vcat(
        [
            vec(sum(model.θ[d][m] .* model.X[d][m][:, 2]', dims=2))
            for m in 1:model.M
        ]...
    )
end

function calculate_Ndivζ(model::IMMCTM, d::Int)
    return vcat(
        [
            fill(model.N[d][m] / model.ζ[d][m], model.K[m]) for m in 1:model.M
        ]...
    )
end

function update_λ!(model::IMMCTM, d::Int)
    opt = Opt(:LD_MMA, sum(model.K))
    xtol_rel!(opt, 1e-4)
    xtol_abs!(opt, 1e-4)

    Ndivζ = calculate_Ndivζ(model, d)
    sumθ = calculate_sumθ(model, d)

    max_objective!(
        opt,
        (λ, ∇λ) -> λ_objective(
            λ, ∇λ, model.ν[d], Ndivζ, sumθ, model.μ, model.invΣ
        )
    )
    (optobj, optλ, ret) = optimize(opt, model.λ[d])
    model.λ[d] .= optλ
end

function update_ν!(model::IMMCTM, d::Int)
    opt = Opt(:LD_MMA, sum(model.K))
    lower_bounds!(opt, 1e-7)
    xtol_rel!(opt, 1e-4)
    xtol_abs!(opt, 1e-4)

    Ndivζ = calculate_Ndivζ(model, d)

    max_objective!(
        opt,
        (ν, ∇ν) -> ν_objective(ν, ∇ν, model.λ[d], Ndivζ, model.μ, model.invΣ)
    )
    (optobj, optν, ret) = optimize(opt, model.ν[d])
    model.ν[d] .= optν
end

function update_ζ!(model::IMMCTM, d::Int)
    start = 1
    for m in 1:model.M
        stop = start + model.K[m] - 1
        model.ζ[d][m] = sum(
            exp.(model.λ[d][start:stop] .+ 0.5 * model.ν[d][start:stop])
        )
        start += model.K[m]
    end
end

function update_θ!(model::IMMCTM, d::Int)
    offset = 0
    for m in 1:model.M
        for w in 1:size(model.X[d][m])[1]
            v = model.X[d][m][w, 1]

            for k in 1:model.K[m]
                model.θ[d][m][k, w] = exp(model.λ[d][offset + k])

                for i in 1:model.I[m]
                    model.θ[d][m][k, w] *= exp(
                        model.Elnϕ[m][k][i][model.features[m][v, i]]
                    )
                end
            end

        end
        model.θ[d][m] ./= sum(model.θ[d][m], dims=1)
        offset += model.K[m]
    end
end

function update_μ!(model::IMMCTM)
    model.μ .= mean(model.λ)
end

function update_Σ!(model::IMMCTM)
    model.Σ .= sum(diagm.(0 .=> model.ν))
    for d in 1:model.D
        diff = model.λ[d] .- model.μ
        model.Σ .+= diff * diff'
    end
    model.Σ ./= model.D
    model.invΣ .= inv(model.Σ)
end

function update_Elnϕ!(model::IMMCTM)
    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                model.Elnϕ[m][k][i] .= digamma.(model.γ[m][k][i]) .-
                    digamma(sum(model.γ[m][k][i]))
            end
        end
    end
end

function update_γ!(model::IMMCTM)
    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                for j in 1:model.J[m][i]
                    model.γ[m][k][i][j] = model.α[m][i]
                end
            end
        end
    end
    for d in 1:model.D
        for m in 1:model.M
            Nθ = model.θ[d][m] .* model.X[d][m][:, 2]'
            for w in 1:size(model.X[d][m])[1]
                v = model.X[d][m][w, 1]
                for k in 1:model.K[m]
                    for i in 1:model.I[m]
                        model.γ[m][k][i][model.features[m][v, i]] += Nθ[k, w]
                    end
                end
            end
        end
    end
    update_Elnϕ!(model)
end

function update_α!(model::IMMCTM)
    opt = Opt(:LD_MMA, 1)
    lower_bounds!(opt, 1e-7)
    xtol_rel!(opt, 1e-5)
    xtol_abs!(opt, 1e-5)

    for m in 1:model.M
        for i in 1:model.I[m]
            sum_Elnϕ = sum(sum(model.Elnϕ[m][k][i] for k in 1:model.K[m]))

            max_objective!(
                opt,
                (α, ∇α) -> α_objective(α, ∇α, sum_Elnϕ, model.K[m], model.J[m][i])
            )

            (optobj, optα, ret) = optimize(opt, model.α[m][i:i])
            model.α[m][i] = optα[1]
        end
    end
end


function calculate_ElnPϕ(model::IMMCTM)
    lnp = 0.0

    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                lnp -= logmvbeta(fill(model.α[m][i], model.J[m][i]))
                for j in 1:model.J[m][i]
                    lnp += (model.α[m][i] - 1) * model.Elnϕ[m][k][i][j]
                end
            end
        end
    end

    return lnp
end

function calculate_ElnPη(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        diff = model.λ[d] .- model.μ
        lnp += 0.5 * (
            logdet(model.invΣ) -
            sum(model.K) * log(2π) -
            tr(diagm(0 => model.ν[d]) * model.invΣ) -
            (diff' * model.invΣ * diff)[1]
        )
    end

    return lnp
end

function calculate_ElnPZ(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        Eeη = exp.(model.λ[d] .+ 0.5model.ν[d])
        sumθ = calculate_sumθ(model, d)
        Ndivζ = calculate_Ndivζ(model, d)

        lnp += sum(model.λ[d] .* sumθ)
        lnp -= sum(Ndivζ .* Eeη) - sum(model.N[d])
        lnp -= sum(model.N[d] .* log.(model.ζ[d]))
    end

    return lnp
end

function calculate_ElnPX(model::IMMCTM)
    lnp = 0.0

    for d in 1:model.D
        for m in 1:model.M
            for w in 1:size(model.X[d][m])[1]
                v = model.X[d][m][w, 1]
                for i in 1:model.I[m]
                    for k in 1:model.K[m]
                        lnp += model.X[d][m][w, 2] * model.θ[d][m][k, w] *
                            model.Elnϕ[m][k][i][model.features[m][v, i]]
                    end
                end
            end
        end
    end

    return lnp
end

function calculate_ElnQϕ(model::IMMCTM)
    lnq = 0.0

    for m in 1:model.M
        for k in 1:model.K[m]
            for i in 1:model.I[m]
                lnq += -logmvbeta(model.γ[m][k][i])
                for j in 1:model.J[m][i]
                    lnq += (model.γ[m][k][i][j] - 1) * model.Elnϕ[m][k][i][j]
                end
            end
        end
    end
    return lnq
end

function calculate_ElnQη(model::IMMCTM)
    lnq = 0.0
    for d in 1:model.D
        lnq += -0.5 * (sum(log.(model.ν[d])) + sum(model.K) * (log(2π) + 1))
    end
    return lnq
end

function calculate_ElnQZ(model::IMMCTM)
    lnq = 0.0
    for d in 1:model.D
        for m in 1:model.M
            lnq += sum(model.X[d][m][:, 2]' .* log.(model.θ[d][m] .^ model.θ[d][m]))
        end
    end
    return lnq
end

function calculate_elbo(model::IMMCTM)
    elbo = 0.0
    elbo += calculate_ElnPϕ(model)
    elbo += calculate_ElnPη(model)
    elbo += calculate_ElnPZ(model)
    elbo += calculate_ElnPX(model)
    elbo -= calculate_ElnQϕ(model)
    elbo -= calculate_ElnQη(model)
    elbo -= calculate_ElnQZ(model)
    return elbo
end

function calculate_docmodality_loglikelihood(X::Matrix{Int},
        η::Vector{Float64}, ϕ::Vector{Vector{Vector{Float64}}},
        features::Matrix{Int})
    props = exp.(η) ./ sum(exp.(η))

    K = length(η)
    I = size(features)[2]

    ll = 0.0
    for w in 1:size(X, 1)
        v = X[w, 1]
        pw = 0.0
        for k in 1:K
            tmp = props[k]
            for i in 1:I
                tmp *= ϕ[k][i][features[v, i]]
            end
            pw += tmp
        end
        ll += X[w, 2] * log(pw)
    end

    return ll / sum(X[:, 2])
end

function calculate_modality_loglikelihood(X::Vector{Matrix{Int}},
        η::Vector{Vector{Float64}}, ϕ::Vector{Vector{Vector{Float64}}},
        features::Matrix{Int})
    D = length(X)

    ll = 0.0
    N = 0
    for d in 1:D
        doc_N = sum(X[d][:, 2])
        if doc_N > 0
            doc_ll = calculate_docmodality_loglikelihood(
                X[d], η[d], ϕ, features
            )
            ll += doc_ll * doc_N
            N += doc_N
        end
    end

    return ll / N
end

function calculate_loglikelihoods(X::Vector{Vector{Matrix{Int}}},
        model::IMMCTM)
    ll = Array{Float64}(undef, model.M)

    offset = 1
    for m in 1:model.M
        mk = offset:(offset + model.K[m] - 1)
        η = [model.λ[d][mk] for d in 1:model.D]
        Xm = [X[d][m] for d in 1:model.D]
        ϕ = [
            [model.γ[m][k][i] ./ sum(model.γ[m][k][i]) for i in 1:model.I[m]]
            for k in 1:model.K[m]
        ]

        ll[m] = calculate_modality_loglikelihood(Xm, η, ϕ, model.features[m])

        offset += model.K[m]
    end

    return ll
end

function fitdoc!(model::IMMCTM, d::Int)
    update_ζ!(model, d)
    update_θ!(model, d)
    update_ν!(model, d)
    update_λ!(model, d)
end

function fit!(model::IMMCTM; maxiter=100, tol=1e-4, verbose=true, autoα=false)
    ll = Vector{Float64}[]

    for iter in 1:maxiter
        for d in 1:model.D
            fitdoc!(model, d)
        end

        update_μ!(model)
        update_Σ!(model)
        update_γ!(model)
        if autoα
            update_α!(model)
        end

        push!(ll, calculate_loglikelihoods(model.X, model))
        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll, tol=tol)
            model.converged = true
            break
        end
    end
    model.elbo = calculate_elbo(model)
    model.ll = ll[end]

    return ll
end

function fit_heldout(Xheldout::Vector{Vector{Matrix{Int}}}, model::IMMCTM;
        maxiter=100, verbose=false)

    heldout_model = IMMCTM(model.K, model.α, model.features, Xheldout)
    heldout_model.μ .= model.μ
    heldout_model.Σ .= model.Σ
    heldout_model.invΣ .= model.invΣ
    heldout_model.γ = deepcopy(model.γ)
    heldout_model.Elnϕ = deepcopy(model.Elnϕ)

    ll = Vector{Float64}[]
    for iter in 1:maxiter
        for d in 1:heldout_model.D
            fitdoc!(heldout_model, d)
        end

        push!(ll, calculate_loglikelihoods(Xheldout, heldout_model))

        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll)
            heldout_model.converged = true
            break
        end
    end

    return heldout_model
end

function predict_modality_η(Xobs::Vector{Vector{Matrix{Int}}}, m::Int,
        model::IMMCTM; maxiter=100, verbose=false)
    obsM = setdiff(1:model.M, m)

    moffset = sum(model.K[1:(m - 1)])
    unobsMK = (moffset + 1):(moffset + model.K[m])
    obsMK = setdiff(1:sum(model.K), unobsMK)

    obsmodel = IMMCTM(model.K[obsM], model.α[obsM], model.features[obsM], Xobs)
    obsmodel.μ .= model.μ[obsMK]
    obsmodel.Σ .= model.Σ[obsMK, obsMK]
    obsmodel.invΣ .= model.invΣ[obsMK, obsMK]
    obsmodel.γ = deepcopy(model.γ[obsM])
    obsmodel.Elnϕ = deepcopy(model.Elnϕ[obsM])

    ll = Vector{Float64}[]
    for iter in 1:maxiter
        for d in 1:obsmodel.D
            fitdoc!(obsmodel, d)
        end

        push!(ll, calculate_loglikelihoods(Xobs, obsmodel))

        if verbose
            println("$iter\tLog-likelihoods: ", join(ll[end], ", "))
        end

        if length(ll) > 10 && check_convergence(ll)
            obsmodel.converged = true
            break
        end
    end

    if !obsmodel.converged
        warn("model not converged.")
    end

    η = [
        (
            model.μ[unobsMK] .+ model.Σ[unobsMK, obsMK] *
            model.invΣ[obsMK, obsMK] * (obsmodel.λ[d] .- model.μ[obsMK])
        )
        for d in 1:obsmodel.D
    ]

    return η
end
