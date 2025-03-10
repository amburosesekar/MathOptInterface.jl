const EMPTYSTRING = ""

# Implementation of MOI for AbstractModel
abstract type AbstractModelLike{T} <: MOI.ModelLike end
abstract type AbstractOptimizer{T} <: MOI.AbstractOptimizer end
const AbstractModel{T} = Union{AbstractModelLike{T},AbstractOptimizer{T}}

# Variables
function MOI.get(model::AbstractModel, ::MOI.NumberOfVariables)::Int64
    if model.variable_indices === nothing
        return model.num_variables_created
    else
        return length(model.variable_indices)
    end
end

function MOI.add_variable(model::AbstractModel{T}) where {T}
    vi = VI(model.num_variables_created += 1)
    push!(model.single_variable_mask, 0x0)
    push!(model.lower_bound, zero(T))
    push!(model.upper_bound, zero(T))
    if model.variable_indices !== nothing
        push!(model.variable_indices, vi)
    end
    return vi
end

function MOI.add_variables(model::AbstractModel, n::Integer)
    return [MOI.add_variable(model) for i in 1:n]
end

"""
    remove_variable(f::MOI.AbstractFunction, s::MOI.AbstractSet, vi::MOI.VariableIndex)

Return a tuple `(g, t)` representing the constraint `f`-in-`s` with the
variable `vi` removed. That is, the terms containing the variable `vi` in the
function `f` are removed and the dimension of the set `s` is updated if
needed (e.g. when `f` is a `VectorOfVariables` with `vi` being one of the
variables).
"""
remove_variable(f, s, vi::VI) = remove_variable(f, vi), s
function remove_variable(f::MOI.VectorOfVariables, s, vi::VI)
    g = remove_variable(f, vi)
    if length(g.variables) != length(f.variables)
        t = MOI.update_dimension(s, length(g.variables))
    else
        t = s
    end
    return g, t
end

filter_variables(keep::F, f, s) where {F<:Function} = filter_variables(keep, f), s
function filter_variables(keep::F, f::MOI.VectorOfVariables, s) where {F<:Function}
    g = filter_variables(keep, f)
    if length(g.variables) != length(f.variables)
        t = MOI.update_dimension(s, length(g.variables))
    else
        t = s
    end
    return g, t
end
function _delete_variable(
    model::AbstractModel{T},
    vi::MOI.VariableIndex,
) where {T}
    MOI.throw_if_not_valid(model, vi)
    model.single_variable_mask[vi.value] = 0x0
    if model.variable_indices === nothing
        model.variable_indices =
            Set(MOI.get(model, MOI.ListOfVariableIndices()))
    end
    delete!(model.variable_indices, vi)
    model.name_to_var = nothing
    delete!(model.var_to_name, vi)
    model.name_to_con = nothing
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.EqualTo{T}}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.GreaterThan{T}}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.LessThan{T}}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.Interval{T}}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.Integer}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.ZeroOne}(vi.value),
    )
    delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.Semicontinuous{T}}(vi.value),
    )
    return delete!(
        model.con_to_name,
        MOI.ConstraintIndex{MOI.SingleVariable,MOI.Semiinteger{T}}(vi.value),
    )
end
function MOI.delete(model::AbstractModel, vi::MOI.VariableIndex)
    vis = [vi]
    broadcastcall(model) do constrs
        _throw_if_cannot_delete(constrs, vis, vis)
    end
    _delete_variable(model, vi)
    broadcastcall(model) do constrs
        _deleted_constraints(constrs, vi) do ci
            delete!(model.con_to_name, ci)
        end
    end
    model.objective = remove_variable(model.objective, vi)
    model.name_to_con = nothing
    return
end

function MOI.delete(model::AbstractModel, vis::Vector{MOI.VariableIndex})
    if isempty(vis)
        # In `keep`, we assume that `model.variable_indices !== nothing` so
        # at least one variable need to be deleted.
        return
    end
    fast_in_vis = Set(vis)
    broadcastcall(model) do constrs
        _throw_if_cannot_delete(constrs, vis, fast_in_vis)
    end
    broadcastcall(model) do constrs
        _deleted_constraints(constrs, vis) do ci
            delete!(model.con_to_name, ci)
        end
    end
    for vi in vis
        _delete_variable(model, vi)
    end
    keep(vi::MOI.VariableIndex) = vi in model.variable_indices
    model.objective = filter_variables(keep, model.objective)
    model.name_to_con = nothing
    return
end

function MOI.is_valid(
    model::AbstractModel,
    ci::CI{MOI.SingleVariable,S},
) where {S}
    return 1 ≤ ci.value ≤ length(model.single_variable_mask) &&
           !iszero(
        model.single_variable_mask[ci.value] & single_variable_flag(S),
    )
end

function MOI.is_valid(model::AbstractModel, ci::CI{F,S}) where {F,S}
    if MOI.supports_constraint(model, F, S)
        return MOI.is_valid(constraints(model, ci), ci)
    else
        return false
    end
end

function MOI.is_valid(model::AbstractModel, vi::VI)
    if model.variable_indices === nothing
        return 1 ≤ vi.value ≤ model.num_variables_created
    else
        return in(vi, model.variable_indices)
    end
end

function MOI.get(model::AbstractModel, ::MOI.ListOfVariableIndices)
    if model.variable_indices === nothing
        return VI.(1:model.num_variables_created)
    else
        vis = collect(model.variable_indices)
        sort!(vis, by = vi -> vi.value) # It needs to be sorted by order of creation
        return vis
    end
end

# Names
MOI.supports(::AbstractModel, ::MOI.Name) = true
function MOI.set(model::AbstractModel, ::MOI.Name, name::String)
    return model.name = name
end
MOI.get(model::AbstractModel, ::MOI.Name) = model.name

MOI.supports(::AbstractModel, ::MOI.VariableName, vi::Type{VI}) = true
function MOI.set(model::AbstractModel, ::MOI.VariableName, vi::VI, name::String)
    model.var_to_name[vi] = name
    model.name_to_var = nothing # Invalidate the name map.
    return
end

function MOI.get(model::AbstractModel, ::MOI.VariableName, vi::VI)
    return get(model.var_to_name, vi, EMPTYSTRING)
end

"""
    build_name_to_var_map(con_to_name::Dict{MOI.VariableIndex, String})

Create and return a reverse map from name to variable index, given a map from
variable index to name. The special value `MOI.VariableIndex(0)` is used to
indicate that multiple variables have the same name.
"""
function build_name_to_var_map(var_to_name::Dict{VI,String})
    name_to_var = Dict{String,VI}()
    for (var, var_name) in var_to_name
        if haskey(name_to_var, var_name)
            # 0 is a special value that means this string does not map to
            # a unique variable name.
            name_to_var[var_name] = VI(0)
        else
            name_to_var[var_name] = var
        end
    end
    return name_to_var
end

function throw_multiple_name_error(::Type{MOI.VariableIndex}, name::String)
    return error("Multiple variables have the name $name.")
end
function throw_multiple_name_error(::Type{<:MOI.ConstraintIndex}, name::String)
    return error("Multiple constraints have the name $name.")
end
function throw_if_multiple_with_name(::Nothing, ::String) end
function throw_if_multiple_with_name(index::MOI.Index, name::String)
    if iszero(index.value)
        throw_multiple_name_error(typeof(index), name)
    end
end

function MOI.get(model::AbstractModel, ::Type{VI}, name::String)
    if model.name_to_var === nothing
        # Rebuild the map.
        model.name_to_var = build_name_to_var_map(model.var_to_name)
    end
    result = get(model.name_to_var, name, nothing)
    throw_if_multiple_with_name(result, name)
    return result
end

function MOI.get(
    model::AbstractModel,
    ::MOI.ListOfVariableAttributesSet,
)::Vector{MOI.AbstractVariableAttribute}
    return isempty(model.var_to_name) ? [] : [MOI.VariableName()]
end

MOI.supports(model::AbstractModel, ::MOI.ConstraintName, ::Type{<:CI}) = true
function MOI.set(
    model::AbstractModel,
    ::MOI.ConstraintName,
    ci::CI,
    name::String,
)
    model.con_to_name[ci] = name
    model.name_to_con = nothing # Invalidate the name map.
    return
end

function MOI.get(model::AbstractModel, ::MOI.ConstraintName, ci::CI)
    return get(model.con_to_name, ci, EMPTYSTRING)
end

"""
    build_name_to_con_map(con_to_name::Dict{MOI.ConstraintIndex, String})

Create and return a reverse map from name to constraint index, given a map from
constraint index to name. The special value
`MOI.ConstraintIndex{Nothing, Nothing}(0)` is used to indicate that multiple
constraints have the same name.
"""
function build_name_to_con_map(con_to_name::Dict{CI,String})
    name_to_con = Dict{String,CI}()
    for (con, con_name) in con_to_name
        if haskey(name_to_con, con_name)
            name_to_con[con_name] = CI{Nothing,Nothing}(0)
        else
            name_to_con[con_name] = con
        end
    end
    return name_to_con
end

function MOI.get(model::AbstractModel, ConType::Type{<:CI}, name::String)
    if model.name_to_con === nothing
        # Rebuild the map.
        model.name_to_con = build_name_to_con_map(model.con_to_name)
    end
    ci = get(model.name_to_con, name, nothing)
    throw_if_multiple_with_name(ci, name)
    return ci isa ConType ? ci : nothing
end

function MOI.get(
    model::AbstractModel,
    ::MOI.ListOfConstraintAttributesSet,
)::Vector{MOI.AbstractConstraintAttribute}
    return isempty(model.con_to_name) ? [] : [MOI.ConstraintName()]
end

# Objective
MOI.get(model::AbstractModel, ::MOI.ObjectiveSense) = model.sense
MOI.supports(model::AbstractModel, ::MOI.ObjectiveSense) = true
function MOI.set(
    model::AbstractModel{T},
    ::MOI.ObjectiveSense,
    sense::MOI.OptimizationSense,
) where {T}
    if sense == MOI.FEASIBILITY_SENSE
        model.objectiveset = false
        model.objective = zero(MOI.ScalarAffineFunction{T})
    end
    model.senseset = true
    model.sense = sense
    return
end

function MOI.get(model::AbstractModel, ::MOI.ObjectiveFunctionType)
    return MOI.typeof(model.objective)
end
function MOI.get(model::AbstractModel, ::MOI.ObjectiveFunction{T})::T where {T}
    return model.objective
end
function MOI.supports(
    model::AbstractModel{T},
    ::MOI.ObjectiveFunction{<:Union{
        MOI.SingleVariable,
        MOI.ScalarAffineFunction{T},
        MOI.ScalarQuadraticFunction{T},
    }},
) where {T}
    return true
end
function MOI.set(
    model::AbstractModel,
    attr::MOI.ObjectiveFunction{F},
    f::F,
) where {F<:MOI.AbstractFunction}
    if !MOI.supports(model, attr)
        throw(MOI.UnsupportedAttribute(attr))
    end
    model.objectiveset = true
    # f needs to be copied, see #2
    model.objective = copy(f)
    return
end

function MOI.modify(
    model::AbstractModel,
    ::MOI.ObjectiveFunction,
    change::MOI.AbstractFunctionModification,
)
    model.objective = modify_function(model.objective, change)
    model.objectiveset = true
    return
end

function MOI.get(::AbstractModel, ::MOI.ListOfOptimizerAttributesSet)
    return MOI.AbstractOptimizerAttribute[]
end
function MOI.get(
    model::AbstractModel,
    ::MOI.ListOfModelAttributesSet,
)::Vector{MOI.AbstractModelAttribute}
    listattr = MOI.AbstractModelAttribute[]
    if model.senseset
        push!(listattr, MOI.ObjectiveSense())
    end
    if model.objectiveset
        push!(listattr, MOI.ObjectiveFunction{typeof(model.objective)}())
    end
    if !isempty(model.name)
        push!(listattr, MOI.Name())
    end
    return listattr
end

# Constraints
single_variable_flag(::Type{<:MOI.EqualTo}) = 0x1
single_variable_flag(::Type{<:MOI.GreaterThan}) = 0x2
single_variable_flag(::Type{<:MOI.LessThan}) = 0x4
single_variable_flag(::Type{<:MOI.Interval}) = 0x8
single_variable_flag(::Type{MOI.Integer}) = 0x10
single_variable_flag(::Type{MOI.ZeroOne}) = 0x20
single_variable_flag(::Type{<:MOI.Semicontinuous}) = 0x40
single_variable_flag(::Type{<:MOI.Semiinteger}) = 0x80
# If a set is added here, a line should be added in
# `MOI.delete(::AbstractModel, ::MOI.VariableIndex)`

function flag_to_set_type(flag::UInt8, ::Type{T}) where {T}
    if flag == 0x1
        return MOI.EqualTo{T}
    elseif flag == 0x2
        return MOI.GreaterThan{T}
    elseif flag == 0x4
        return MOI.LessThan{T}
    elseif flag == 0x8
        return MOI.Interval{T}
    elseif flag == 0x10
        return MOI.Integer
    elseif flag == 0x20
        return MOI.ZeroOne
    elseif flag == 0x40
        return MOI.Semicontinuous{T}
    else
        @assert flag == 0x80
        return MOI.Semiinteger{T}
    end
end

# Julia doesn't infer `S1` correctly, so we use a function barrier to improve
# inference.
function _throw_if_lower_bound_set(variable, S2, mask, T)
    S1 = flag_to_set_type(mask, T)
    throw(MOI.LowerBoundAlreadySet{S1,S2}(variable))
    return
end

function throw_if_lower_bound_set(variable, S2, mask, T)
    lower_mask = mask & LOWER_BOUND_MASK
    if iszero(lower_mask)
        return  # No lower bound set.
    elseif iszero(single_variable_flag(S2) & LOWER_BOUND_MASK)
        return  # S2 isn't related to the lower bound.
    end
    return _throw_if_lower_bound_set(variable, S2, lower_mask, T)
end

# Julia doesn't infer `S1` correctly, so we use a function barrier to improve
# inference.
function _throw_if_upper_bound_set(variable, S2, mask, T)
    S1 = flag_to_set_type(mask, T)
    throw(MOI.UpperBoundAlreadySet{S1,S2}(variable))
    return
end

function throw_if_upper_bound_set(variable, S2, mask, T)
    upper_mask = mask & UPPER_BOUND_MASK
    if iszero(upper_mask)
        return  # No upper bound set.
    elseif iszero(single_variable_flag(S2) & UPPER_BOUND_MASK)
        return  # S2 isn't related to the upper bound.
    end
    return _throw_if_upper_bound_set(variable, S2, upper_mask, T)
end

# Sets setting lower bound:
extract_lower_bound(set::MOI.EqualTo) = set.value
function extract_lower_bound(
    set::Union{MOI.GreaterThan,MOI.Interval,MOI.Semicontinuous,MOI.Semiinteger},
)
    return set.lower
end
# 0xcb = 0x80 | 0x40 | 0x8 | 0x2 | 0x1
const LOWER_BOUND_MASK = 0xcb

# Sets setting upper bound:
extract_upper_bound(set::MOI.EqualTo) = set.value
function extract_upper_bound(
    set::Union{MOI.LessThan,MOI.Interval,MOI.Semicontinuous,MOI.Semiinteger},
)
    return set.upper
end
# 0xcd = 0x80 | 0x40 | 0x8 | 0x4 | 0x1
const UPPER_BOUND_MASK = 0xcd

const SUPPORTED_VARIABLE_SCALAR_SETS{T} = Union{
    MOI.EqualTo{T},
    MOI.GreaterThan{T},
    MOI.LessThan{T},
    MOI.Interval{T},
    MOI.Integer,
    MOI.ZeroOne,
    MOI.Semicontinuous{T},
    MOI.Semiinteger{T},
}
function MOI.supports_constraint(
    ::AbstractModel{T},
    ::Type{MOI.SingleVariable},
    ::Type{<:SUPPORTED_VARIABLE_SCALAR_SETS{T}},
) where {T}
    return true
end

function MOI.add_constraint(
    model::AbstractModel{T},
    f::MOI.SingleVariable,
    s::SUPPORTED_VARIABLE_SCALAR_SETS{T},
) where {T}
    flag = single_variable_flag(typeof(s))
    index = f.variable.value
    mask = model.single_variable_mask[index]
    throw_if_lower_bound_set(f.variable, typeof(s), mask, T)
    throw_if_upper_bound_set(f.variable, typeof(s), mask, T)
    # No error should be thrown now, we can modify `model`.
    if !iszero(flag & LOWER_BOUND_MASK)
        model.lower_bound[index] = extract_lower_bound(s)
    end
    if !iszero(flag & UPPER_BOUND_MASK)
        model.upper_bound[index] = extract_upper_bound(s)
    end
    model.single_variable_mask[index] = mask | flag
    return CI{MOI.SingleVariable,typeof(s)}(index)
end

function MOI.add_constraint(model::AbstractModel, func::MOI.AbstractFunction, set::MOI.AbstractSet)
    if MOI.supports_constraint(model, typeof(func), typeof(set))
        return MOI.add_constraint(constraints(model, typeof(func), typeof(set)), func, set)
    else
        throw(MOI.UnsupportedConstraint{typeof(func),typeof(set)}())
    end
end
function constraints(
    model::AbstractModel,
    ci::MOI.ConstraintIndex{F,S}
) where {F,S}
    if !MOI.supports_constraint(model, F, S)
        throw(MOI.InvalidIndex(ci))
    end
    return constraints(model, F, S)
end
function MOI.get(model::AbstractModel, attr::Union{MOI.AbstractFunction, MOI.AbstractSet}, ci::MOI.ConstraintIndex)
    return MOI.get(constraints(model, ci), attr, ci)
end
function MOI.modify(model::AbstractModel, ci::MOI.ConstraintIndex, change)
    return MOI.modify(constraints(model, ci), ci, change)
end

function _delete_constraint(
    model::AbstractModel,
    ci::MOI.ConstraintIndex{MOI.SingleVariable,S},
) where {S}
    MOI.throw_if_not_valid(model, ci)
    model.single_variable_mask[ci.value] &= ~single_variable_flag(S)
    return
end

function _delete_constraint(model::AbstractModel, ci::MOI.ConstraintIndex)
    MOI.delete(constraints(model, ci), ci)
    return
end

function MOI.delete(model::AbstractModel, ci::MOI.ConstraintIndex)
    _delete_constraint(model, ci)
    model.name_to_con = nothing
    delete!(model.con_to_name, ci)
    return
end

function MOI.modify(
    model::AbstractModel,
    ci::MOI.ConstraintIndex,
    change::MOI.AbstractFunctionModification,
)
    MOI.modify(constraints(model, ci), ci, change)
    return
end

function MOI.set(
    ::AbstractModel,
    ::MOI.ConstraintFunction,
    ::MOI.ConstraintIndex{MOI.SingleVariable,<:MOI.AbstractScalarSet},
    ::MOI.SingleVariable,
)
    return throw(MOI.SettingSingleVariableFunctionNotAllowed())
end
function MOI.set(
    model::AbstractModel{T},
    ::MOI.ConstraintSet,
    ci::MOI.ConstraintIndex{MOI.SingleVariable,S},
    set::S,
) where {T,S<:SUPPORTED_VARIABLE_SCALAR_SETS{T}}
    MOI.throw_if_not_valid(model, ci)
    flag = single_variable_flag(typeof(set))
    if !iszero(flag & LOWER_BOUND_MASK)
        model.lower_bound[ci.value] = extract_lower_bound(set)
    end
    if !iszero(flag & UPPER_BOUND_MASK)
        model.upper_bound[ci.value] = extract_upper_bound(set)
    end
    return
end

function MOI.set(
    model::AbstractModel,
    attr::MOI.ConstraintSet,
    ci::MOI.ConstraintIndex{<:MOI.AbstractFunction,S},
    set::S,
) where {S<:MOI.AbstractSet}
    MOI.set(constraints(model, ci), attr, ci, set)
    return
end

function MOI.set(
    model::AbstractModel,
    attr::MOI.ConstraintFunction,
    ci::MOI.ConstraintIndex{F,<:MOI.AbstractSet},
    func::F,
) where {F<:MOI.AbstractFunction}
    MOI.set(constraints(model, ci), attr, ci, func)
    return
end

function MOI.get(
    model::AbstractModel,
    ::MOI.NumberOfConstraints{MOI.SingleVariable,S},
) where {S}
    flag = single_variable_flag(S)
    return count(mask -> !iszero(flag & mask), model.single_variable_mask)
end
function MOI.get(model::AbstractModel, noc::MOI.NumberOfConstraints{F,S}) where {F,S}
    if MOI.supports_constraint(model, F, S)
        return MOI.get(constraints(model, F, S), noc)
    else
        return 0
    end
end

function _add_contraint_type(
    list,
    model::AbstractModel,
    S::Type{<:MOI.AbstractScalarSet},
)
    flag = single_variable_flag(S)
    if any(mask -> !iszero(flag & mask), model.single_variable_mask)
        push!(list, (MOI.SingleVariable, S))
    end
    return
end
function MOI.get(model::AbstractModel{T}, loc::MOI.ListOfConstraints) where {T}
    list = broadcastvcat(model) do v
        MOI.get(v, loc)
    end
    for S in (
        MOI.EqualTo{T},
        MOI.GreaterThan{T},
        MOI.LessThan{T},
        MOI.Interval{T},
        MOI.Semicontinuous{T},
        MOI.Semiinteger{T},
        MOI.Integer,
        MOI.ZeroOne,
    )
        _add_contraint_type(list, model, S)
    end
    return list
end

function MOI.get(
    model::AbstractModel,
    ::MOI.ListOfConstraintIndices{MOI.SingleVariable,S},
) where {S}
    list = CI{MOI.SingleVariable,S}[]
    flag = single_variable_flag(S)
    for (index, mask) in enumerate(model.single_variable_mask)
        if !iszero(mask & flag)
            push!(list, CI{MOI.SingleVariable,S}(index))
        end
    end
    return list
end

function MOI.get(model::AbstractModel, loc::MOI.ListOfConstraintIndices{F,S}) where {F,S}
    if MOI.supports_constraint(model, F, S)
        return MOI.get(constraints(model, F, S), loc)
    else
        return MOI.ConstraintIndex{F,S}[]
    end
end

function MOI.get(
    model::AbstractModel,
    ::MOI.ConstraintFunction,
    ci::CI{MOI.SingleVariable},
)
    MOI.throw_if_not_valid(model, ci)
    return MOI.SingleVariable(MOI.VariableIndex(ci.value))
end
function MOI.get(
    model::AbstractModel,
    attr::Union{MOI.ConstraintFunction, MOI.ConstraintSet},
    ci::MOI.ConstraintIndex
)
    return MOI.get(constraints(model, ci), attr, ci)
end

function _get_single_variable_set(
    model::AbstractModel,
    S::Type{<:MOI.EqualTo},
    index,
)
    return MOI.EqualTo(model.lower_bound[index])
end
function _get_single_variable_set(
    model::AbstractModel,
    S::Type{<:Union{MOI.GreaterThan,MOI.EqualTo}},
    index,
)
    # Lower and upper bounds are equal for `EqualTo`, we can take either of them.
    return S(model.lower_bound[index])
end
function _get_single_variable_set(
    model::AbstractModel,
    S::Type{<:MOI.LessThan},
    index,
)
    return S(model.upper_bound[index])
end
function _get_single_variable_set(
    model::AbstractModel,
    S::Type{<:Union{MOI.Interval,MOI.Semicontinuous,MOI.Semiinteger}},
    index,
)
    return S(model.lower_bound[index], model.upper_bound[index])
end
function _get_single_variable_set(
    ::AbstractModel,
    S::Type{<:Union{MOI.Integer,MOI.ZeroOne}},
    index,
)
    return S()
end
function MOI.get(
    model::AbstractModel,
    ::MOI.ConstraintSet,
    ci::CI{MOI.SingleVariable,S},
) where {S}
    MOI.throw_if_not_valid(model, ci)
    return _get_single_variable_set(model, S, ci.value)
end

function MOI.is_empty(model::AbstractModel)
    return isempty(model.name) &&
               !model.senseset &&
               !model.objectiveset &&
               isempty(model.objective.terms) &&
               iszero(model.objective.constant) &&
               iszero(model.num_variables_created) &&
               mapreduce_constraints(MOI.is_empty, &, model, true)
end
function MOI.empty!(model::AbstractModel{T}) where {T}
    model.name = ""
    model.senseset = false
    model.sense = MOI.FEASIBILITY_SENSE
    model.objectiveset = false
    model.objective = zero(MOI.ScalarAffineFunction{T})
    model.num_variables_created = 0
    model.variable_indices = nothing
    model.single_variable_mask = UInt8[]
    model.lower_bound = T[]
    model.upper_bound = T[]
    empty!(model.var_to_name)
    model.name_to_var = nothing
    empty!(model.con_to_name)
    model.name_to_con = nothing
    broadcastcall(MOI.empty!, model)
    return
end


function MOI.copy_to(dest::AbstractModel, src::MOI.ModelLike; kws...)
    return automatic_copy_to(dest, src; kws...)
end
supports_default_copy_to(model::AbstractModel, copy_names::Bool) = true

# Allocate-Load Interface
# Even if the model does not need it and use default_copy_to, it could be used
# by a layer that needs it
supports_allocate_load(model::AbstractModel, copy_names::Bool) = true

function allocate_variables(model::AbstractModel, nvars)
    return MOI.add_variables(model, nvars)
end
allocate(model::AbstractModel, attr...) = MOI.set(model, attr...)
function allocate_constraint(
    model::AbstractModel,
    f::MOI.AbstractFunction,
    s::MOI.AbstractSet,
)
    return MOI.add_constraint(model, f, s)
end

function load_variables(::AbstractModel, nvars) end
function load(::AbstractModel, attr...) end
function load_constraint(
    ::AbstractModel,
    ::CI,
    ::MOI.AbstractFunction,
    ::MOI.AbstractSet,
) end

# Can be used to access constraints of a model
"""
broadcastcall(f::Function, model::AbstractModel)

Calls `f(contrs)` for every vector `constrs::Vector{ConstraintIndex{F, S}, F, S}` of the model.

# Examples

To add all constraints of the model to a solver `solver`, one can do
```julia
_addcon(solver, ci, f, s) = MOI.add_constraint(solver, f, s)
function _addcon(solver, constrs::Vector)
    for constr in constrs
        _addcon(solver, constr...)
    end
end
MOIU.broadcastcall(constrs -> _addcon(solver, constrs), model)
```
"""
function broadcastcall end

"""
broadcastvcat(f::Function, model::AbstractModel)

Calls `f(contrs)` for every vector `constrs::Vector{ConstraintIndex{F, S}, F, S}` of the model and concatenate the results with `vcat` (this is used internally for `ListOfConstraints`).

# Examples

To get the list of all functions:
```julia
_getfun(ci, f, s) = f
_getfun(cindices::Tuple) = _getfun(cindices...)
_getfuns(constrs::Vector) = _getfun.(constrs)
MOIU.broadcastvcat(_getfuns, model)
```
"""
function broadcastvcat end

function mapreduce_constraints end

# Macro to generate Model
abstract type Constraints{F} end

abstract type SymbolFS end
struct SymbolFun <: SymbolFS
    s::Union{Symbol,Expr}
    typed::Bool
    cname::Expr # `esc(scname)` or `esc(vcname)`
end
struct SymbolSet <: SymbolFS
    s::Union{Symbol,Expr}
    typed::Bool
end

# QuoteNode prevents s from being interpolated and keeps it as a symbol
# Expr(:., MOI, s) would be MOI.s
# Expr(:., MOI, $s) would be Expr(:., MOI, EqualTo)
# Expr(:., MOI, :($s)) would be Expr(:., MOI, :EqualTo)
# Expr(:., MOI, :($(QuoteNode(s)))) is Expr(:., MOI, :(:EqualTo)) <- what we want

# (MOI, :Zeros) -> :(MOI.Zeros)
# (:Zeros) -> :(MOI.Zeros)
_set(s::SymbolSet) = esc(s.s)
_fun(s::SymbolFun) = esc(s.s)
function _typedset(s::SymbolSet)
    if s.typed
        :($(_set(s)){T})
    else
        _set(s)
    end
end
function _typedfun(s::SymbolFun)
    if s.typed
        :($(_fun(s)){T})
    else
        _fun(s)
    end
end

# Base.lowercase is moved to Unicode.lowercase in Julia v0.7
using Unicode

_field(s::SymbolFS) = Symbol(replace(lowercase(string(s.s)), "." => "_"))

_getC(s::SymbolSet) = :(VectorOfConstraints{F,$(_typedset(s))})
_getC(s::SymbolFun) = _typedfun(s)

_getCV(s::SymbolSet) = :($(_getC(s))())
_getCV(s::SymbolFun) = :($(s.cname){T,$(_getC(s))}())

_callfield(f, s::SymbolFS) = :($f(model.$(_field(s))))
_broadcastfield(b, s::SymbolFS) = :($b(f, model.$(_field(s))))
_mapreduce_field(s::SymbolFS) = :(cur = $MOIU.mapreduce_constraints(f, op, model.$(_field(s)), cur))
_mapreduce_constraints(s::SymbolFS) = :(cur = op(cur, f(model.$(_field(s)))))

# This macro is for expert/internal use only. Prefer the concrete Model type
# instantiated below.
"""
    macro model(
        model_name,
        scalar_sets,
        typed_scalar_sets,
        vector_sets,
        typed_vector_sets,
        scalar_functions,
        typed_scalar_functions,
        vector_functions,
        typed_vector_functions,
        is_optimizer = false
    )

Creates a type `model_name` implementing the MOI model interface and containing
`scalar_sets` scalar sets `typed_scalar_sets` typed scalar sets, `vector_sets`
vector sets, `typed_vector_sets` typed vector sets, `scalar_functions` scalar
functions, `typed_scalar_functions` typed scalar functions, `vector_functions`
vector functions and `typed_vector_functions` typed vector functions.
To give no set/function, write `()`, to give one set `S`, write `(S,)`.

The function [`MathOptInterface.SingleVariable`](@ref) should not be given in
`scalar_functions`. The model supports [`MathOptInterface.SingleVariable`](@ref)-in-`F`
constraints where `F` is [`MathOptInterface.EqualTo`](@ref),
[`MathOptInterface.GreaterThan`](@ref), [`MathOptInterface.LessThan`](@ref),
[`MathOptInterface.Interval`](@ref), [`MathOptInterface.Integer`](@ref),
[`MathOptInterface.ZeroOne`](@ref), [`MathOptInterface.Semicontinuous`](@ref)
or [`MathOptInterface.Semiinteger`](@ref). The sets supported
with the [`MathOptInterface.SingleVariable`](@ref) cannot be controlled from the
macro, use the [`UniversalFallback`](@ref) to support more sets.

This macro creates a model specialized for specific types of constraint,
by defining specialized structures and methods. To create a model that,
in addition to be optimized for specific constraints, also support arbitrary
constraints and attributes, use [`UniversalFallback`](@ref).

This implementation of the MOI model certifies that the constraint indices, in
addition to being different between constraints `F`-in-`S` for the same types
`F` and `S`, are also different between constraints for different types `F` and
`S`. This means that for constraint indices `ci1`, `ci2` of this model,
`ci1 == ci2` if and only if `ci1.value == ci2.value`. This fact can be used to
use the the value of the index directly in a dictionary representing a mapping
between constraint indices and something else.

If `is_optimizer = true`, the resulting struct is a subtype of
of `MOIU.AbstractOptimizer`, which is a subtype of
[`MathOptInterface.AbstractOptimizer`](@ref), otherwise, it is a subtype of
`MOIU.AbstractModelLike`, which is a subtype of
[`MathOptInterface.ModelLike`](@ref).

### Examples

The model describing an linear program would be:
```julia
@model(LPModel,                                                   # Name of model
      (),                                                         # untyped scalar sets
      (MOI.EqualTo, MOI.GreaterThan, MOI.LessThan, MOI.Interval), #   typed scalar sets
      (MOI.Zeros, MOI.Nonnegatives, MOI.Nonpositives),            # untyped vector sets
      (),                                                         #   typed vector sets
      (),                                                         # untyped scalar functions
      (MOI.ScalarAffineFunction,),                                #   typed scalar functions
      (MOI.VectorOfVariables,),                                   # untyped vector functions
      (MOI.VectorAffineFunction,),                                #   typed vector functions
      false
    )
```

Let `MOI` denote `MathOptInterface`, `MOIU` denote `MOI.Utilities` and
`MOIU.ConstraintEntry{F, S}` be defined as `MOI.Tuple{MOI.ConstraintIndex{F, S}, F, S}`.
The macro would create the types:
```julia
struct LPModelScalarConstraints{T, F <: MOI.AbstractScalarFunction} <: MOIU.Constraints{F}
    equalto::Vector{MOIU.ConstraintEntry{F, MOI.EqualTo{T}}}
    greaterthan::Vector{MOIU.ConstraintEntry{F, MOI.GreaterThan{T}}}
    lessthan::Vector{MOIU.ConstraintEntry{F, MOI.LessThan{T}}}
    interval::Vector{MOIU.ConstraintEntry{F, MOI.Interval{T}}}
end
struct LPModelVectorConstraints{T, F <: MOI.AbstractVectorFunction} <: MOIU.Constraints{F}
    zeros::Vector{MOIU.ConstraintEntry{F, MOI.Zeros}}
    nonnegatives::Vector{MOIU.ConstraintEntry{F, MOI.Nonnegatives}}
    nonpositives::Vector{MOIU.ConstraintEntry{F, MOI.Nonpositives}}
end
mutable struct LPModel{T} <: MOIU.AbstractModel{T}
    name::String
    sense::MOI.OptimizationSense
    objective::Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}, MOI.ScalarQuadraticFunction{T}}
    num_variables_created::Int64
    # If nothing, no variable has been deleted so the indices of the
    # variables are VI.(1:num_variables_created)
    variable_indices::Union{Nothing, Set{MOI.VariableIndex}}
    # Union of flags of `S` such that a `SingleVariable`-in-`S`
    # constraint was added to the model and not deleted yet.
    single_variable_mask::Vector{UInt8}
    # Lower bound set by `SingleVariable`-in-`S` where `S`is
    # `GreaterThan{T}`, `EqualTo{T}` or `Interval{T}`.
    lower_bound::Vector{T}
    # Lower bound set by `SingleVariable`-in-`S` where `S`is
    # `LessThan{T}`, `EqualTo{T}` or `Interval{T}`.
    upper_bound::Vector{T}
    var_to_name::Dict{MOI.VariableIndex, String}
    # If `nothing`, the dictionary hasn't been constructed yet.
    name_to_var::Union{Dict{String, MOI.VariableIndex}, Nothing}
    con_to_name::Dict{MOI.ConstraintIndex, String}
    name_to_con::Union{Dict{String, MOI.ConstraintIndex}, Nothing}
    scalaraffinefunction::LPModelScalarConstraints{T, MOI.ScalarAffineFunction{T}}
    vectorofvariables::LPModelVectorConstraints{T, MOI.VectorOfVariables}
    vectoraffinefunction::LPModelVectorConstraints{T, MOI.VectorAffineFunction{T}}
end
```
The type `LPModel` implements the MathOptInterface API except methods specific
to solver models like `optimize!` or `getattribute` with `VariablePrimal`.
"""
macro model(
    model_name,
    ss,
    sst,
    vs,
    vst,
    sf,
    sft,
    vf,
    vft,
    is_optimizer = false,
)
    scalar_sets = [SymbolSet.(ss.args, false); SymbolSet.(sst.args, true)]
    vector_sets = [SymbolSet.(vs.args, false); SymbolSet.(vst.args, true)]

    scname = esc(Symbol(string(model_name) * "ScalarConstraints"))
    vcname = esc(Symbol(string(model_name) * "VectorConstraints"))

    esc_model_name = esc(model_name)
    header = if is_optimizer
        :($(esc(model_name)){T} <: AbstractOptimizer{T})
    else
        :($(esc(model_name)){T} <: AbstractModelLike{T})
    end

    scalar_funs = [
        SymbolFun.(sf.args, false, Ref(scname))
        SymbolFun.(sft.args, true, Ref(scname))
    ]
    vector_funs = [
        SymbolFun.(vf.args, false, Ref(vcname))
        SymbolFun.(vft.args, true, Ref(vcname))
    ]
    funs = [scalar_funs; vector_funs]

    scalarconstraints = :(
        struct $scname{T,F<:$MOI.AbstractScalarFunction} <: Constraints{F} end
    )
    vectorconstraints = :(
        struct $vcname{T,F<:$MOI.AbstractVectorFunction} <: Constraints{F} end
    )
    for (c, sets) in
        ((scalarconstraints, scalar_sets), (vectorconstraints, vector_sets))
        for s in sets
            field = _field(s)
            push!(c.args[3].args, :($field::$(_getC(s))))
        end
    end

    modeldef = quote
        mutable struct $header
            name::String
            senseset::Bool
            sense::$MOI.OptimizationSense
            objectiveset::Bool
            objective::Union{
                $MOI.SingleVariable,
                $MOI.ScalarAffineFunction{T},
                $MOI.ScalarQuadraticFunction{T},
            }
            num_variables_created::Int64
            # If nothing, no variable has been deleted so the indices of the
            # variables are VI.(1:num_variables_created)
            variable_indices::Union{Nothing,Set{$VI}}
            # Union of flags of `S` such that a `SingleVariable`-in-`S`
            # constraint was added to the model and not deleted yet.
            single_variable_mask::Vector{UInt8}
            # Lower bound set by `SingleVariable`-in-`S` where `S`is
            # `GreaterThan{T}`, `EqualTo{T}` or `Interval{T}`.
            lower_bound::Vector{T}
            # Lower bound set by `SingleVariable`-in-`S` where `S`is
            # `LessThan{T}`, `EqualTo{T}` or `Interval{T}`.
            upper_bound::Vector{T}
            var_to_name::Dict{$VI,String}
            # If `nothing`, the dictionary hasn't been constructed yet.
            name_to_var::Union{Dict{String,$VI},Nothing}
            con_to_name::Dict{$CI,String}
            name_to_con::Union{Dict{String,$CI},Nothing}
            # A useful dictionary for extensions to store things. These are
            # _not_ copied between models!
            ext::Dict{Symbol,Any}
        end
    end
    for f in funs
        cname = f.cname
        field = _field(f)
        push!(modeldef.args[2].args[3].args, :($field::$cname{T,$(_getC(f))}))
    end

    code = quote
        function $MOIU.broadcastcall(f::F, model::$esc_model_name) where {F<:Function}
            return $(Expr(:block, _broadcastfield.(Ref(:(broadcastcall)), funs)...))
        end
        function $MOIU.broadcastvcat(f::F, model::$esc_model_name) where {F<:Function}
            return vcat($(_broadcastfield.(Ref(:(broadcastvcat)), funs)...))
        end
        function $MOIU.mapreduce_constraints(f::Function, op::Function, model::$esc_model_name, cur)
            return $(Expr(:block, _mapreduce_field.(funs)...))
        end
    end
    for (cname, sets) in ((scname, scalar_sets), (vcname, vector_sets))
        code = quote
            $code
            function $MOIU.broadcastcall(f::F, model::$cname) where {F<:Function}
                return $(Expr(:block, _callfield.(:f, sets)...))
            end
            function $MOIU.broadcastvcat(f::F, model::$cname) where {F<:Function}
                return vcat($(_callfield.(:f, sets)...))
            end
            function $MOIU.mapreduce_constraints(f::Function, op::Function, model::$cname, cur)
                return $(Expr(:block, _mapreduce_constraints.(sets)...))
            end
        end
    end

    for (c, sets) in ((scname, scalar_sets), (vcname, vector_sets))
        for s in sets
            set = _set(s)
            field = _field(s)
            code = quote
                $code
                function $MOIU.constraints(
                    model::$c,
                    ::Type{<:$set},
                ) where {F}
                    return model.$field
                end
            end
        end
    end

    for f in funs
        fun = _fun(f)
        field = _field(f)
        code = quote
            $code
            function $MOIU.constraints(
                model::$esc_model_name,
                ::Type{<:$fun},
                ::Type{S}
            ) where S
                return $MOIU.constraints(model.$field, S)
            end
        end
    end

    code = quote
        $scalarconstraints
        function $scname{T,F}() where {T,F}
            return $scname{T,F}($(_getCV.(scalar_sets)...))
        end

        $vectorconstraints
        function $vcname{T,F}() where {T,F}
            return $vcname{T,F}($(_getCV.(vector_sets)...))
        end

        $modeldef
        function $esc_model_name{T}() where {T}
            return $esc_model_name{T}(
                "",
                false,
                $MOI.FEASIBILITY_SENSE,
                false,
                $SAF{T}($MOI.ScalarAffineTerm{T}[], zero(T)),
                0,
                nothing,
                UInt8[],
                T[],
                T[],
                Dict{$VI,String}(),
                nothing,
                Dict{$CI,String}(),
                nothing,
                Dict{Symbol,Any}(),
                $(_getCV.(funs)...),
            )
        end

        function $MOI.supports_constraint(
            model::$esc_model_name{T},
            ::Type{<:Union{$(_typedfun.(scalar_funs)...)}},
            ::Type{<:Union{$(_typedset.(scalar_sets)...)}},
        ) where {T}
            return true
        end
        function $MOI.supports_constraint(
            model::$esc_model_name{T},
            ::Type{<:Union{$(_typedfun.(vector_funs)...)}},
            ::Type{<:Union{$(_typedset.(vector_sets)...)}},
        ) where {T}
            return true
        end

        $code
    end
    return code
end

const LessThanIndicatorSetOne{T} =
    MOI.IndicatorSet{MOI.ACTIVATE_ON_ONE,MOI.LessThan{T}}
const LessThanIndicatorSetZero{T} =
    MOI.IndicatorSet{MOI.ACTIVATE_ON_ZERO,MOI.LessThan{T}}

@model(
    Model,
    (MOI.ZeroOne, MOI.Integer),
    (
        MOI.EqualTo,
        MOI.GreaterThan,
        MOI.LessThan,
        MOI.Interval,
        MOI.Semicontinuous,
        MOI.Semiinteger,
    ),
    (
        MOI.Reals,
        MOI.Zeros,
        MOI.Nonnegatives,
        MOI.Nonpositives,
        MOI.Complements,
        MOI.NormInfinityCone,
        MOI.NormOneCone,
        MOI.SecondOrderCone,
        MOI.RotatedSecondOrderCone,
        MOI.GeometricMeanCone,
        MOI.ExponentialCone,
        MOI.DualExponentialCone,
        MOI.RelativeEntropyCone,
        MOI.NormSpectralCone,
        MOI.NormNuclearCone,
        MOI.PositiveSemidefiniteConeTriangle,
        MOI.PositiveSemidefiniteConeSquare,
        MOI.RootDetConeTriangle,
        MOI.RootDetConeSquare,
        MOI.LogDetConeTriangle,
        MOI.LogDetConeSquare,
    ),
    (
        MOI.PowerCone,
        MOI.DualPowerCone,
        MOI.SOS1,
        MOI.SOS2,
        LessThanIndicatorSetOne,
        LessThanIndicatorSetZero,
    ),
    (),
    (MOI.ScalarAffineFunction, MOI.ScalarQuadraticFunction),
    (MOI.VectorOfVariables,),
    (MOI.VectorAffineFunction, MOI.VectorQuadraticFunction)
)

@doc raw"""

An implementation of `ModelLike` that supports all functions and sets defined
in MOI. It is parameterized by the coefficient type.

# Examples
```jl
model = Model{Float64}()
x = add_variable(model)
```
"""
Model
