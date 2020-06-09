using LinearAlgebra: eigen
using NLsolve: nlsolve

export IonConfiguration
export ions
export linear_equilibrium_positions, Anm, linearchain, characteristic_length_scale
export get_vibrational_modes


"""
    IonConfiguration
Physical configuration of ions. Stores a collection of ions and  information about the 
interactions of their center of mass motion.
"""
abstract type IonConfiguration end

# required functions
ions(I::IonConfiguration)::Vector{Ion} = I.ions


#############################################################################################
# linearchain - a linear Coulomb crystal
#############################################################################################

"""
    linear_equilibrium_positions(N::Int)
Returns the scaled equilibrium positions of `N` ions in a harmonic potential, assuming that
all ions have the same mass. 
[ref](https://link.springer.com/content/pdf/10.1007%2Fs003400050373.pdf)
"""
function linear_equilibrium_positions(N::Int) 
    function f!(F, x, N) 
        for i in 1:N
            F[i] = begin
                x[i] - 
                sum([1 / (x[i] - x[j])^2 for j in 1:i-1]) + 
                sum([1 / (x[i] - x[j])^2 for j in i+1:N])
            end
        end
    end
    
    function j!(J, x, N)
        for i in 1:N, j in 1:N
            if i ≡ j
                J[i, j] = begin
                    1 + 
                    2 * sum([1 / (x[i] - x[j])^3 for j in 1:i-1]) - 
                    2 * sum([1 / (x[i] - x[j])^3 for j in i+1:N])
                end
            else
                J[i, j] = begin
                    -2 * sum([1 / (x[i] - x[j])^3 for j in 1:i-1]) + 
                    2 * sum([1 / (x[i] - x[j])^3 for j in i+1:N])
                end
            end
        end
    end
    # see eq.8 in the ref to see where (2.018/N^0.559) comes from
    if isodd(N)
        initial_x = [(2.018 / N^0.559)*i for i in -N÷2:N÷2]
    else
        initial_x = [(2.018 / N^0.559)*i for i in filter(x->x≠0, collect(-N÷2:N÷2))]
    end
    sol = nlsolve((F,x) -> f!(F,x,N), (J,x) -> j!(J,x,N), initial_x, method=:newton)
    sol.zero
end

"""
    characteristic_length_scale(M::Real, ν::Real)
Returns the characteristic length scale for a linear chain of identical ions of mass `M`
and with axial trap frequency 2π × ν.
"""
characteristic_length_scale(M::Real, ν::Real) = (e^2 / (4π * ϵ₀ * M * (2π * ν)^2))^(1/3)

"""
    Anm(N::Real, com::NamedTuple; axis::NamedTuple{(:x,:y,:z)}=ẑ)
Computes the normal modes and corresponding trap frequencies for a collection of N ions in a 
linear Coloumb crystal.

#### args
* `N`: number of ions
* `com`: NamedTuple of COM frequencies for the different axes, `(x=Real, y=Real, z=Real)`. 
    The ``z``-axis is taken to be parallel to the axis of the crystal.
* `axis`: the axis for which to compute the normal modes

#### returns
An array of tuples with first element the frequency of the normal mode and 2nd element the 
corresponding eigenvector.
"""
function Anm(N::Int, com::NamedTuple{(:x,:y,:z)}; axis::NamedTuple{(:x,:y,:z)}=ẑ)
    @assert axis in [x̂, ŷ, ẑ] "axis can be x̂, ŷ, ẑ"
    axis == ẑ ? a = 2 : a = -1
    l = linear_equilibrium_positions(N)
    axis_dict = Dict([(x̂, :x), (ŷ, :y), (ẑ, :z)])
    sa = axis_dict[axis]
    β = com[sa] / com.z
    A = Array{Real}(undef, N, N)
    for n in 1:N, j in 1:N
        if n ≡ j
            A[n, j] = β^2 + a * sum([ 1 / abs(l[j] - l[p])^3 for p in 1:N if p != j])
        else
            A[n, j] = -a / abs(l[j] - l[n])^3
        end
    end
    a = eigen(A)
    for i in a.values
        @assert i > 0 """
            ($(axis_dict[axis])=$(com[sa]), z=$(com.z)) outside stability region for $N ions
        """
    end
    a1 = [sqrt(i) * com.z for i in a.values]
    a2 = a.vectors
    for i in 1:size(a2, 2)
        _sparsify!(view(a2, :,i), 1e-5)
    end
    if axis == ẑ
        return [(a1[i], a2[:,i]) for i in 1:length(a1)]
    else
        a = reverse([(a1[i], a2[:,i]) for i in 1:length(a1)])
        return a
    end
end

_sparsify!(x, eps) = @. x[abs(x) < eps] = 0

"""
    linearchain(;
            ions::Vector{Ion}, com_frequencies::NamedTuple{(:x,:y,:z)}, 
            vibrational_modes::NamedTuple{(:x,:y,:z),Tuple{Vararg{Vector{vibrational_mode},3}}}
        )

#### user-defined fields
* `ions::Vector{Ion}`: a list of ions that compose the linear Coulomb crystal
* `com_frequencies::NamedTuple{(:x,:y,:z),Tuple{Vararg{Vector{vibrational_mode},3}}}`: 
        Describes the COM frequencies `(x=ν_x, y=ν_y, z=ν_z)`. The ``z``-axis is taken to be 
        parallel to the crystal's symmetry axis.
* `vibrational_modes::NamedTuple{(:x,:y,:z)}`:  e.g. `vibrational_modes=(x=[1], y=[2], z=[1,2])`. 
    Specifies the axis and a list of integers which correspond to the ``i^{th}`` farthest 
    mode away from the COM for that axis. For example, `selected_modes=(z=[2])` would 
    specify the axial stretch mode. These are the modes that will be modeled in the chain.
#### derived fields
* `full_normal_mode_description::NamedTuple{(:x,:y,:z)}`: For each axis, this contains an 
    array of tuples where the first element is a vibrational frequency [Hz] and the second
    element is a vector describing the corresponding normalized normal mode structure.
"""
struct linearchain <: IonConfiguration
    ions::Vector{<:Ion}
    com_frequencies::NamedTuple{(:x,:y,:z)}
    vibrational_modes::NamedTuple{(:x,:y,:z),Tuple{Vararg{Vector{vibrational_mode},3}}}
    full_normal_mode_description::NamedTuple{(:x,:y,:z)}
    function linearchain( 
            ions, com_frequencies, selected_modes::NamedTuple{(:x,:y,:z)}, 
            
        )
        for i in 1:length(ions)-1, j in i+1:length(ions)
            if ions[j] == ions[i]
                ions[j] = copy(ions[i])
                @warn "some ions point to the same thing. Making copies."
                break
            end
        end
        N = length(ions)
        A = (x=Anm(N, com_frequencies, axis=x̂), 
             y=Anm(N, com_frequencies, axis=ŷ),
             z=Anm(N, com_frequencies, axis=ẑ))
        vm = (x=Vector{Vibration}(undef, 0),
              y=Vector{Vibration}(undef, 0),
              z=Vector{Vibration}(undef, 0))
        r = [x̂, ŷ, ẑ]
        for (i, modes) in enumerate(selected_modes), mode in modes
            push!(vm[i], vibrational_mode(A[i][mode]..., axis=r[i]))
        end
        l = linear_equilibrium_positions(length(ions))
        l0 = characteristic_length_scale(m_ca40, com_frequencies.z) 
        for (i, ion) in enumerate(ions)
            Core.setproperty!(ion, :number, i)
            Core.setproperty!(ion, :position, l[i] * l0)
        end
        new(ions, com_frequencies, vm, A)
    end
end

function get_vibrational_modes(lc::linearchain)
    collect(Iterators.flatten(lc.vibrational_modes))
end

function Base.print(lc::linearchain)
    print("$(length(lc.ions)) ions\n")
    print("com frequencies: $(lc.com_frequencies)\n")
    print("selected vibrational_modes: $(lc.vibrational_modes)\n")
end

function Base.show(io::IO, lc::linearchain)  # suppress long output
    print(io, "linearchain($(length(lc.ions)) ions)")
end

# function Base.getindex(lc::linearchain, s::String)
#     v = lc.vibrational_modes
#     V = vcat(v.x, v.y, v.z)
#     for obj in V
#         if obj.label == s
#             return obj
#         end
#     end
# end
