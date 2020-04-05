using SparseArrays: rowvals, nzrange, nonzeros
using FunctionWrappers: FunctionWrapper
using QuantumOptics: SparseOperator, embed


export hamiltonian
export get_η


"""
    hamiltonian(
            T::trap, timescale::Real=1e-6, lamb_dicke_order::Int=1, rwa_cutoff::Real=Inf
        )
Constructs the Hamiltonian for `T` as a function of time. Return type is a function 
`h(t::Real, ψ)` that, itself, returns a `QuantumOptics.SparseOperator`.

#### args
* `timescale`: e.g. a value of 1e-6 will take time to be in ``\\mu s``
* `lamb_dicke_order`: only consider terms that change the phonon number by up to this value.
    Note: this isn't quite the same thing as the Lamb-Dicke approximation since setting
    `lamb_dicke_order=1` will retain, for example, terms proportional to ``a^\\dagger a ``.
* `rwa_cutoff`: drop terms in the Hamiltonian that oscillate faster than this cutoff. **Note:
    if not using an RWA set to `Inf` (rather than a large number) for faster performance.**
"""
function hamiltonian(
        T::trap; timescale::Real=1e-6, lamb_dicke_order::Int=1, rwa_cutoff::Real=Inf
    ) 
    hamiltonian(T, T.configuration, timescale, lamb_dicke_order, rwa_cutoff) 
end


#############################################################################################
# Hamiltonian for a linear configuration of ions
#############################################################################################

function hamiltonian(
        T::trap, configuration::linearchain, timescale::Real, lamb_dicke_order::Int, 
        rwa_cutoff::Real
    )
    b, indxs, cindxs = _setup_base_hamiltonian(T, timescale, lamb_dicke_order, rwa_cutoff)
    aui, gbi, gbs, bfunc, δνi, δνfuncs = _setup_fluctuation_hamiltonian(T, timescale)
    S = SparseOperator(get_basis(T))
    function f(t, ψ)
        @inbounds begin
            @simd for i in 1:length(indxs)
                bt_i, conj_bt_i = b[i](t)::Tuple{ComplexF64,ComplexF64}
                @simd for j in 1:length(indxs[i])
                    i1, i2 = indxs[i][j]
                    S.data[i1, i2] = bt_i
                    S.data[i2, i1] = conj(bt_i)
                    if length(cindxs[i]) != 0
                        flag = cindxs[i][1][1]
                        i3, i4 = cindxs[i][j+1]
                        if flag == -1
                            S.data[i3, i4] = -conj_bt_i
                            S.data[i4, i3] = -conj(conj_bt_i)
                        else
                            S.data[i3, i4] = conj_bt_i
                            S.data[i4, i3] = conj(conj_bt_i)
                        end
                    end
                end
            end
            if length(gbi) == 0 && length(δνi) == 0
                return S
            else
                @simd for indx in aui
                    S.data[indx, indx] = complex(0)
                end
                @simd for i in 1:length(gbi)
                    zeeman_t = bfunc(t)::Float64
                    @simd for j in 1:length(gbi[i])
                        indx = gbi[i][j]
                        S.data[indx, indx] += zeeman_t * gbs[i][j]
                    end
                end
                @simd for i in 1:length(δνi)
                    δν_t = δνfuncs[i](t)::Float64
                    @simd for n in 1:length(δνi[i])
                        @simd for indx in δνi[i][n]
                            S.data[indx, indx] += n * δν_t
                        end
                    end
                end
            end
        end
        return S
    end
    return f
end

#=
The purpose of the hamiltonian function is to evaluate a vector of time-dependent functions
and use the returned values to update, in-place, a pre-allocated array.

The pre-allocated array holds the full Hamiltonian -- a tensor product defined over all of the 
individual ion and vibrational mode subspaces -- at a particular point in time.

However, we don't know a priori the exact form of the Hilbert space or the details of the
Hamiltonian's time dependence, since it will be defined by the user.

The _setup_hamiltonian function extracts this user-defined information from a <:Trap struct 
and converts it into two vector of vectors of indices, corresponding to redundant (see note 
below) matrix elements of the Hamiltonian, and a matched vector of time-dependent functions 
for updating these elements.

------- Note -------
Since the terms of the Hamiltonian will always be of the form of a single ion operator
tensored with a single vibrational mode operator, there will be a lot of redundancy in the
Hamiltonian's matrix elements. E.g.

                                     [ σ₊ ⊗ D(α(t))      0         ]  
             H = 𝐼 ⊗ σ₊ ⊗ D(α(t)) =  [       0        σ₊ ⊗ D(α(t)) ]

So to avoid unnecessarily evaluating functions more than once, _setup_hamiltonian also returns 
a vector of vectors of indices that keep track of this redundancy.

Also, there's some additional symmetry of the displacement operator (when not applying an RWA)
            <m|D(α)|n> = (-1)^(n-m) × conjugate(<n|D(α)|m>)
We keep track of this in a separate vector of vectors of indices.
=#
function _setup_base_hamiltonian(T, timescale, lamb_dicke_order, rwa_cutoff)
    ηm = _ηmatrix(T, timescale)
    Δm = _Δmatrix(T, timescale)
    Ωm = _Ωmatrix(T, timescale)
    ions = T.configuration.ions
    modes = get_vibrational_modes(T.configuration)
    
    indxs_dict = Dict()
    repeated_indices = Vector{Vector{Tuple{Int64,Int64}}}(undef, 0)
    conj_repeated_indices = Vector{Vector{Tuple{Int64,Int64}}}(undef, 0)
    functions = FunctionWrapper[]

    # iterate over ions, lasers and ion-laser transitions
    for n in eachindex(ions), m in eachindex(T.lasers), (ti, tr) in enumerate(_transitions(ions[n]))
        Δ = Δm[n, m][ti]
        Ω = Ωm[n, m][ti]
        if sum(Ω.(abs.(0:1e-2:100))) == 0  # needs better solution
            # e.g. the laser doesn't shine on this ion
            continue 
        end  
        
        # iterate over vibrational modes
        for l in eachindex(modes)
            η = ηm[n, m, l]
            ν = modes[l].ν
            δν = modes[l].δν
            mode_basis = modes[l].basis

            # construct an array with dimensions equal to the dimensions of a vibrational mode
            # operator and with indices equal to a complex number z, with z.re equal to the 
            # row and z.im equal to the column.
            mode_dim = mode_basis.shape[1]
            indx_array = zeros(ComplexF64, mode_dim, mode_dim)
            if sum(η.(abs.(0:1e-2:100))) == 0
                for i in 1:mode_dim
                    indx_array[i, i] = complex(i, i)
                end
            else
                for i in 1:mode_dim, j in 1:mode_dim
                    if ((abs(j-i) <= lamb_dicke_order) &&
                        abs((Δ/(2π) + (j-i) * ν * timescale)) < rwa_cutoff * timescale)
                        indx_array[i, j] = complex(i, j)
                    end
                end
            end

            # construct the tensor product 𝐼 ⊗...⊗ σ₊ ⊗ 𝐼 ⊗...⊗ indx_array ⊗ 𝐼 ⊗... 𝐼
            ion_op = sigma(ions[n], tr[2], tr[1])
            mode_op = SparseOperator(mode_basis, indx_array)
            A = embed(get_basis(T), [n, length(ions)+l], [ion_op, mode_op]).data

            # See where subspace operators have been mapped after embedding
            for i in 1:mode_dim, j in (rwa_cutoff == Inf ? collect(1:i) : 1:mode_dim)
                
                # find all locations of i + im*j 
                s_ri = sort(getfield.(findall(x->x.==complex(i, j), A), :I), by=x->x[2])
                
                if length(s_ri) == 0  
                    # this index doesn't exist due to Lamd-Dicke approx and/or RWA
                    continue
                end
                
                # if not RWA, find all locations of j + im*i since these values are trivially
                # related to their conjugates
                if i != j && rwa_cutoff == Inf
                    s_cri = sort(getfield.(findall(x->x.==complex(j, i), A), :I), by=x->x[2])
                    if isodd(abs(i-j))
                        pushfirst!(s_cri, (-1, 0))
                    else
                        pushfirst!(s_cri, (0, 0))
                    end
                else
                    s_cri = []
                end

                # push information to top-level lists, construct time-dep function
                row, col = s_ri[1]
                if haskey(indxs_dict, s_ri[1]) 
                    # this will happen when multiple lasers address the same transition
                    functions[indxs_dict[row, col]] = let 
                            a = functions[indxs_dict[row, col]]
                            FunctionWrapper{Tuple{ComplexF64,ComplexF64},Tuple{Float64}}(
                               t -> @fastmath a(t) .+ _D(Ω(t), Δ, η(t), ν, timescale, i, j, t))
                        end
                else
                    push!(functions, FunctionWrapper{Tuple{ComplexF64,ComplexF64},Tuple{Float64}}(
                            t -> @fastmath _D(Ω(t), Δ, η(t), ν, timescale, i, j, t)
                        ))
                    push!(repeated_indices, s_ri)
                    push!(conj_repeated_indices, s_cri)
                    indxs_dict[row, col] = length(repeated_indices)
                end
            end
        end
    end
    functions, repeated_indices, conj_repeated_indices
end


function _setup_base_hamiltonian_old(T, timescale, lamb_dicke_order, rwa_cutoff)
    ηm = _ηmatrix(T, timescale)
    Δm = _Δmatrix(T, timescale)
    Ωm = _Ωmatrix(T, timescale)
    ions = T.configuration.ions
    modes = get_vibrational_modes(T.configuration)
    
    indxs_dict = Dict()
    repeated_indices = Vector{Vector{Tuple{Int64,Int64}}}(undef, 0)
    conj_repeated_indices = Vector{Vector{Tuple{Int64,Int64}}}(undef, 0)
    functions = FunctionWrapper[]

    # iterate over ions, lasers and ion-laser transitions
    for n in eachindex(ions), m in eachindex(T.lasers), (ti, tr) in enumerate(_transitions(ions[n]))
        Δ = Δm[n, m][ti]
        Ω = Ωm[n, m][ti]
        if sum(Ω.(abs.(0:1e-2:100))) == 0  # needs better solution
            # e.g. the laser doesn't shine on this ion
            continue 
        end  
        
        # iterate over vibrational modes
        for l in eachindex(modes)
            η = ηm[n, m, l]
            ν = modes[l].ν
            δν = modes[l].δν
            mode_basis = modes[l].basis

            # construct an array with dimensions equal to the dimensions of a vibrational mode
            # operator and with indices equal to a complex number z, with z.re equal to the 
            # row and z.im equal to the column.
            mode_dim = mode_basis.shape[1]
            indx_array = zeros(ComplexF64, mode_dim, mode_dim)
            if sum(η.(abs.(0:1e-2:100))) == 0
                for i in 1:mode_dim
                    indx_array[i, i] = complex(i, i)
                end
            else
                for i in 1:mode_dim, j in 1:mode_dim
                    if ((abs(j-i) <= lamb_dicke_order) &&
                        abs((Δ/(2π) + (j-i) * ν * timescale)) < rwa_cutoff * timescale)
                        indx_array[i, j] = complex(i, j)
                    end
                end
            end

            # construct the tensor product 𝐼 ⊗...⊗ σ₊ ⊗ 𝐼 ⊗...⊗ indx_array ⊗ 𝐼 ⊗... 𝐼
            ion_op = sigma(ions[n], tr[2], tr[1])
            mode_op = SparseOperator(mode_basis, indx_array)
            A = embed(get_basis(T), [n, length(ions)+l], [ion_op, mode_op]).data

            # See where subspace operators have been mapped after embedding
            for i in 1:mode_dim, j in (rwa_cutoff == Inf ? collect(1:i) : 1:mode_dim)
                
                # find all locations of i + im*j 
                s_ri = sort(getfield.(findall(x->x.==complex(i, j), A), :I), by=x->x[2])
                
                if length(s_ri) == 0  
                    # this index doesn't exist due to Lamd-Dicke approx and/or RWA
                    continue
                end
                
                # if not RWA, find all locations of j + im*i since these values are trivially
                # related to their conjugates
                if i != j && rwa_cutoff == Inf
                    s_cri = sort(getfield.(findall(x->x.==complex(j, i), A), :I), by=x->x[2])
                    if isodd(abs(i-j))
                        pushfirst!(s_cri, (-1, 0))
                    else
                        pushfirst!(s_cri, (0, 0))
                    end
                else
                    s_cri = []
                end

                # push information to top-level lists, construct time-dep function
                row, col = s_ri[1]
                if haskey(indxs_dict, s_ri[1]) #&& abs(row) + abs(col) != 0
                    # this will happen when multiple lasers address the same transition
                    functions[indxs_dict[row, col]] = let 
                            a = functions[indxs_dict[row, col]]
                            FunctionWrapper{Tuple{ComplexF64,ComplexF64},Tuple{Float64}}(
                               t -> @fastmath a(t) .+ _D(Ω(t), Δ, η(t), ν, timescale, i, j, t))
                        end
                else
                    push!(functions, FunctionWrapper{Tuple{ComplexF64,ComplexF64},Tuple{Float64}}(
                            t -> @fastmath _D(Ω(t), Δ, η(t), ν, timescale, i, j, t)
                        ))
                    push!(repeated_indices, s_ri)
                    push!(conj_repeated_indices, s_cri)
                    indxs_dict[row, col] = length(repeated_indices)
                end
            end
        end
    end
    functions, repeated_indices, conj_repeated_indices
end

# δν(t) × aᵀa terms for Hamiltonain
function _setup_δν_hamiltonian(T, timescale)
    N = length(T.configuration.ions)
    modes = get_vibrational_modes(T.configuration)
    δν_indices = Vector{Vector{Vector{Int64}}}(undef, 0)
    δν_functions = FunctionWrapper[]
    for l in eachindex(modes)
        δν = modes[l].δν
        if sum(δν.(abs.(0 : 1e-2 * timescale : 100 * timescale))) == 0  # needs better solution
            continue
        end
        push!(δν_functions, FunctionWrapper{Float64,Tuple{Float64}}(
                    t -> @fastmath 2π * δν(t) * timescale
                ))
        δν_indices_l = Vector{Vector{Int64}}(undef, 0)
        δν = modes[l].δν
        mode_basis = modes[l].basis
        mode_op = number(mode_basis)
        A = embed(get_basis(T), [N+l], [mode_op]).data
        mode_dim = modes[l].basis.shape[1]
        for i in 1:mode_dim-1
            indices = [x[1] for x in getfield.(findall(x->x.==complex(i, 0), A), :I)]
            push!(δν_indices_l, indices)
        end
        push!(δν_indices, δν_indices_l)
    end
    δν_indices, δν_functions
end

# Hamiltonian terms for global Bfield fluctuations
function _setup_global_B_hamiltonian(T, timescale)
    ions = T.configuration.ions
    global_B_indices = Vector{Vector{Int64}}(undef, 0)
    global_B_scales = Vector{Float64}(undef, 0)
    transitions_list = []
    δB = T.δB
    bfunc = FunctionWrapper{Float64,Tuple{Float64}}(t -> 2π * δB(t) * timescale)
    if sum(T.δB.(abs.(0 : 1e-2 * timescale : 100 * timescale))) == 0  # needs better solution
        return global_B_indices, global_B_scales, bfunc
    end
    for n in eachindex(ions), (ti, tr) in enumerate(_transitions(ions[n]))
        for trs in tr
            if trs in transitions_list
                continue
            else
                push!(transitions_list, trs)
            end
            ion_op = sigma(ions[n], trs, trs)
            A = embed(get_basis(T), [n], [ion_op]).data
            indices = [x[1] for x in getfield.(findall(x->x.==complex(1, 0), A), :I)]
            push!(global_B_indices, indices)
            push!(global_B_scales, zeeman_shift(1, ions[n].level_structure[trs]))
        end
    end
    global_B_indices, global_B_scales, bfunc
end

function _setup_fluctuation_hamiltonian(T, timescale)
    gbi, gbs, bfunc = _setup_global_B_hamiltonian(T, timescale)
    δνi, δνfuncs = _setup_δν_hamiltonian(T, timescale)
    all_unique_indices = convert(Vector{Int64}, _flattenall(unique([gbi; δνi])))
    all_unique_indices, gbi, gbs, bfunc, δνi, δνfuncs
end

# taken from https://gist.github.com/ivirshup/e9148f01663278ca4972d8a2d9715f72
function _flattenall(a::AbstractArray)
    while any(x->typeof(x)<:AbstractArray, a)
        a = collect(Iterators.flatten(a))
    end
    return a
end

# an array of lamb_dicke parameters for each combination of ion, laser and mode
function _ηmatrix(T, timescale)
    ions = T.configuration.ions
    vms = get_vibrational_modes(T.configuration)
    lasers = T.lasers
    (N, M, L) = map(x -> length(x), [ions, lasers, vms])
    ηnml = Array{Any}(undef, N, M, L)#zeros(Float64, N, M, L)
    for n in 1:N, m in 1:M, l in 1:L
        δν = vms[l].δν
        ν = vms[l].ν
        eta = get_η(vms[l], lasers[m], ions[n], scaled=true)
        ηnml[n, m, l] = FunctionWrapper{Float64,Tuple{Float64}}(t -> eta / √(ν + δν(t)))
    end
    ηnml
end

# returns an array of vectors. the rows and columns of the array refer to ions and lasers,
# respectively. for each row/column we have a vector of detunings from the laser frequency for 
# each ion transition.
# we need this to be separate from _Ωmatrix to make the RWA easy  
function _Δmatrix(T, timescale)
    ions = T.configuration.ions
    lasers = T.lasers
    (N, M) = length(ions), length(lasers)
    B = T.B
    ∇B = T.∇B
    Δnmkj = Array{Vector}(undef, N, M)
    for n in 1:N, m in 1:M
        transitions = _transitions(ions[n])
        Btot = B + ∇B * ions[n].position
        v = Vector{Float64}(undef, 0)
        for t in transitions
            L1 = ions[n].selected_level_structure[t[1]]
            L2 = ions[n].selected_level_structure[t[2]]
            stark_shift = ions[n].stark_shift[t[1]] - ions[n].stark_shift[t[2]]
            ωa = abs(L1.E  + zeeman_shift(Btot, L1) - (L2.E + zeeman_shift(Btot, L2)))
            ωa += stark_shift
            push!(v, 2π * timescale * ((c / lasers[m].λ) + lasers[m].Δ - ωa))
        end
        Δnmkj[n, m] = v
    end
    Δnmkj
end

# returns an array of vectors. the rows and columns of the array refer to ions and lasers,
# respectively. for each row/column we have a vector of coupling strengths between the laser
# and all ion transitions with nonzero matrix element.
function _Ωmatrix(T, timescale)
    ions = T.configuration.ions
    lasers = T.lasers
    (N, M) = length(ions), length(lasers)
    Ωnmkj = Array{Vector}(undef, N, M)
    for n in 1:N, m in 1:M
        E = lasers[m].E
        phase = lasers[m].ϕ
        (γ, ϕ) = map(x -> rad2deg(acos(ndot(T.Bhat, x))), [lasers[m].ϵ, lasers[m].k])
        transitions = _transitions(ions[n])
        v = []
        s_indx = findall(x -> x[1] == n, lasers[m].pointing)  # length(s_indx) == 0 || 1
        length(s_indx) == 0 ? s = 0 : s = lasers[m].pointing[s_indx[1]][2]
        for t in transitions
            Ω0 = 2π * timescale * s * ions[n].selected_matrix_elements[t](1.0, γ, ϕ) / 2.0
            push!(v, FunctionWrapper{ComplexF64,Tuple{Float64}}(
                    t -> Ω0 * E(t) * exp(-im * 2π * phase(t * timescale)))
                )
        end
        Ωnmkj[n, m] = v
    end
    Ωnmkj
end

_transitions(ion) = collect(keys(ion.selected_matrix_elements))

# [σ₊(t)]ₙₘ ⋅ [D(ξ(t))]ₙₘ
function _D(Ω, Δ, η, ν, timescale, n, m, t)
    d = _Dnm(1im * η * exp(im * 2π * ν * timescale * t), n, m)
    g = Ω * exp(-1im * t * Δ)
    (g * d, g * conj(d))
end

# assoicated Laguerre polynomial
function _alaguerre(x::Real, n::Int, k::Int)
    L = 1.0, -x + k + 1
    if n < 2
        return L[n+1]
    end
    for i in 2:n
        L = L[2], ((k + 2i - 1 - x) * L[2] - (k + i - 1) * L[1]) / i
    end
    L[2]
end

# matrix elements of the displacement operator in the Fock Basis
# https://doi.org/10.1103/PhysRev.177.1857
function _Dnm(ξ::Number, n::Int, m::Int)
    if n < m 
        if isodd(abs(n-m))
            return -conj(_Dnm(ξ, m, n)) 
        else
            return conj(_Dnm(ξ, m, n))
        end
    end
    n -= 1; m -= 1
    @fastmath begin
        s = 1.0
        for i in m+1:n
            s *= i
        end
        ret = sqrt(1 / s) *  ξ^(n-m) * exp(-abs2(ξ) / 2.0) * _alaguerre(abs2(ξ), m, n-m)
    end
    if isnan(ret)
        if n == m 
            return 1.0 
        else
            return 0.0
        end
        # return 0.0
    end
    ret
end

# Consider: T = sub_ops[1] ⊗ sub_ops[2] ⊗ ... ⊗ sub_ops[N] (where sub_ops[i] is 
# a 2D matrix). And indices: indxs[1], indxs[2], ..., indsx[N] = (i1, j1), (i2, j2), ..., 
# (iN, jN). This function returns (k, l) such that:
# T[k, l] = sub_ops[1][i1, j1] ⊗ sub_ops[2][i2, j2] ⊗ ... ⊗ sub_ops[N][iN, jN]
function _get_kron_indxs(indxs, sub_ops)
    sub_lengths = []
    for (i, mat) in enumerate(sub_ops)
        pushfirst!(sub_lengths, size(mat)[1])
    end
    row, col = 0, 0
    for (i, indx) in enumerate(reverse(indxs))
        if i == 1
            row += indx[1]
            col += indx[2]
        else
            row += (indx[1] - 1) * prod(sub_lengths[1:i-1])
            col += (indx[2] - 1) * prod(sub_lengths[1:i-1])
        end
    end
    row, col
end

# the is the inverse of _get_kron_indxs.
function _inv_get_kron_indxs(indxs, sub_ops)
    row, col = indxs
    N = length(sub_ops)
    ret_rows, ret_cols, sub_lengths = Int64[], Int64[], Int64[]
    for (i, mat) in enumerate(sub_ops)
        push!(sub_lengths, size(mat)[1])
    end
    for i in 1:N
        tensor_N = prod(sub_lengths[i:N])
        M = tensor_N ÷ sub_lengths[i]
        rowflag, colflag = false, false
        for j in 1:sub_lengths[i]
            if !rowflag && row <= j * M
                push!(ret_rows, j)
                row -= (j - 1) * M
                rowflag = true
            end
            if !colflag && col <= j * M 
                push!(ret_cols, j)
                col -= (j - 1) * M
                colflag = true
            end
            if rowflag && colflag
                break
            end
        end
    end
    collect(zip(ret_rows, ret_cols))
end

"""
    get_η(V::vibrational_mode, L::Laser, I::Ion)
The Lamb-Dicke parameter: 
``|k|cos(\\theta)\\sqrt{\\frac{\\hbar}{2m\\nu}}`` 
for a given vibrational mode, ion and laser.
"""
function get_η(V::vibrational_mode, L::Laser, I::Ion; scaled=false)
    @fastmath begin
        k = 2π / L.λ
        scaled ? ν = 1 : ν = V.ν
        x0 = √(ħ.x / (2 * I.mass.x * 2π * ν))
        cosθ = ndot(L.k, V.axis)
        k * x0 * cosθ * V.mode_structure[I.number]
    end
end
