# SPDX-License-Identifier: LGPL-3.0-only

# Simple search tree for testing cluster functions and for analyzing space optimization strategies

module SearchTreeTest

using CircoCore, DataStructures, LinearAlgebra
import CircoCore.onmessage
import CircoCore.onschedule
import CircoCore.monitorextra
import CircoCore.check_migration

# Infoton optimization parameters
const TARGET_DISTANCE = 300
const I = 1.0

# Tree parameters
const ITEM_COUNT = 2_000_000
const ITEMS_PER_LEAF = 1000
const SIBLINGINFO_FREQ = 1 #0..255
const FULLSPEED_PARALLELISM = 100
const SCHEDULER_TARGET_ACTORCOUNT = 1000.0

# Test Coordinator that fills the tree and sends Search requests to it
mutable struct Coordinator <: AbstractActor
    runmode::UInt8
    size::Int64
    resultcount::UInt64
    lastreportts::UInt64
    root::Addr
    core::CoreState
    Coordinator() = new(STOP, 0, 0, 0)
end

# Implement monitorextra() to publish part of an actor's state
monitorextra(me::Coordinator)  = (
    runmode=me.runmode,    
    size = me.size,
    root =!isnothing(me.root) ? me.root.box : nothing
)

# Debug messages handled by the Coordinator
const STOP = 0
const STEP = 1
const SLOW = 20
const FAST = 98
const FULLSPEED = 100

struct RunFull a::UInt8 end # TODO fix MsgPack to allow empty structs
struct Step a::UInt8 end # TODO Create UI to allow parametrized messages
struct RunSlow a::UInt8 end
struct RunFast a::UInt8 end
struct Stop a::UInt8 end

# Binary search tree that holds a set of TValue values in the leaves (max size of a leaf is ITEMS_PER_LEAF)
mutable struct TreeNode{TValue} <: AbstractActor
    values::SortedSet{TValue}
    size::Int64
    left::Union{Addr, Nothing}
    right::Union{Addr, Nothing}
    sibling::Union{Addr, Nothing}
    splitvalue::Union{TValue, Nothing}
    core::CoreState
    TreeNode(values) = new{eltype(values)}(SortedSet(values), length(values), nothing, nothing, nothing, nothing)
end
monitorextra(me::TreeNode) = 
(left = isnothing(me.left) ? nothing : me.left.box,
 right = isnothing(me.right) ? nothing : me.right.box,
 sibling = isnothing(me.sibling) ? nothing : me.sibling.box,
 splitval = me.splitvalue,
 size = me.size)


# --- Infoton optimization. We overwrite the default behaviors to allow easy experimentation

# Schedulers pull/push their actors based on the number of actors they schedule 
# SCHEDULER_TARGET_ACTOURCOUNT configures the target actorcount.
@inline function actorcount_scheduler_infoton(scheduler, actor::AbstractActor)
    dist = norm(scheduler.pos - actor.core.pos)
    dist === 0.0 && return Infoton(scheduler.pos, 0.0)
    energy = (SCHEDULER_TARGET_ACTORCOUNT - scheduler.actorcount) * 2e-3 # / dist  # disabled: "/ dist" would mean force degrades linearly with distance.
    return Infoton(scheduler.pos, energy)
end

CircoCore.scheduler_infoton(scheduler, actor::AbstractActor) = actorcount_scheduler_infoton(scheduler, actor)

@inline CircoCore.check_migration(me::Union{TreeNode, Coordinator}, alternatives::MigrationAlternatives, service) = begin
    if norm(pos(service) - pos(me)) > 700 # Do not check for alternatives if too close to the current scheduler
        migrate_to_nearest(me, alternatives, service)
    end
end

@inline CircoCore.apply_infoton(targetactor::AbstractActor, infoton::Infoton) = begin
    diff = infoton.sourcepos - targetactor.core.pos
    difflen = norm(diff)
    energy = infoton.energy
    if energy > 0 && difflen < TARGET_DISTANCE
        return nothing
    end
    targetactor.core.pos += diff / difflen * energy * I
    return nothing
end

# --- End of Infoton optimization

# Tree-messages
struct Add{TValue}
    value::TValue
end

struct Search{TValue}
    value::TValue
    searcher::Addr
end

struct SearchResult{TValue}
    value::TValue
    found::Bool
end

struct SetSibling # TODO UnionAll Addr, default Setter and Getter, no more boilerplate like this. See #14
    value::Addr
end

struct SiblingInfo
    size::UInt64
end

genvalue() = rand(UInt32)
nearpos(pos::Pos, maxdistance=10.0) = pos + Pos(rand() * maxdistance, rand() * maxdistance, rand() * maxdistance)

function onschedule(me::Coordinator, service)
    @debug "onschedule: $me"
    me.core.pos = Pos(0, 0, 0)
    me.root = createnode(Array{UInt32}(undef, 0), service, nearpos(me.core.pos))
    if me.runmode !== STOP
        startround(me, service)
    end
end

function createnode(nodevalues, service, pos=nothing)
    node = TreeNode(nodevalues)
    retval = spawn(service, node)
    if !isnothing(pos)
        node.core.pos = pos
    end
    return retval
end

# Starts one or more search rounds. A round means a single search for a random value, the result returning to
# to the coordinator. If the tree is not filled fully (as configured by ITEM_COUNT), then a new value
# may also be inserted with some probability
function startround(me::Coordinator, service, parallel = 1)
    if me.size < ITEM_COUNT && rand() < 0.06 + me.size / ITEM_COUNT * 0.1
        send(service, me, me.root, Add(genvalue()))
        me.size += 1
    end
    me.runmode == STOP && return nothing
    if me.runmode == STEP
        me.runmode = STOP
        return nothing
    end
    if (me.runmode != FULLSPEED && rand() > 0.01 * me.runmode) 
        sleep(0.001)
    end
    for i in 1:parallel
        send(service, me, me.root, Search(genvalue(), addr(me)))
    end
end

function onmessage(me::Coordinator, message::SearchResult, service)
    #me.core.pos = Pos(0, 0, 0)
    me.resultcount += 1
    if time_ns() > me.lastreportts + 10_000_000_000
        @info("#avg searches/sec since last report: $(me.resultcount * 1e9 / (time_ns() - me.lastreportts))")
        me.resultcount = 0
        me.lastreportts = time_ns()
    end
    startround(me, service)
    yield()
end

# When a message comes back as RecipientMoved, the locally stored address of the moved actor has to be updated
# and the message forwarded manually
function onmessage(me::Coordinator, message::RecipientMoved, service) # TODO a default implementation like this
    if !isnothing(me.root) && box(me.root) === box(message.oldaddress)
        me.root = message.newaddress
    else
        @info "unhandled, forwarding: $message" 
    end
    send(service, me, message.newaddress, message.originalmessage)
end

function onmessage(me::Coordinator, message::Stop, service)
    me.runmode = STOP
end

function onmessage(me::Coordinator, message::RunFast, service)
    oldmode = me.runmode
    me.runmode = FAST
    oldmode == STOP && startround(me, service, 80)
end

function onmessage(me::Coordinator, message::RunSlow, service)
    oldmode = me.runmode
    me.runmode = SLOW
    oldmode == STOP && startround(me, service)
end

function onmessage(me::Coordinator, message::RunFull, service)
    oldmode = me.runmode
    me.runmode = FULLSPEED
    oldmode == STOP && startround(me, service, FULLSPEED_PARALLELISM)
end

function onmessage(me::Coordinator, message::Step, service)
    oldmode = me.runmode
    me.runmode = STEP
    oldmode == STOP && startround(me, service)
end

# Splits a leaf by halving it and pushing the parts to the left and righ children
# TODO do it without that much copying
function split(me::TreeNode, service)
    leftvalues = typeof(me.values)()
    rightvalues = typeof(me.values)()
    idx = 1
    splitat = length(me.values) / 2
    split = false
    for value in me.values
        if split
            push!(rightvalues, value)
        else
            push!(leftvalues, value)
            if idx >= splitat
                me.splitvalue = value
                split = true
            end
        end
        idx += 1
    end
    left = TreeNode(leftvalues)
    right = TreeNode(rightvalues)
    me.left = spawn(service, left)
    me.right = spawn(service, right)
    left.core.pos = nearpos(me.core.pos)
    right.core.pos = nearpos(me.core.pos)
    send(service, me, me.left, SetSibling(me.right))
    send(service, me, me.right, SetSibling(me.left))
    empty!(me.values)
end

function onmessage(me::TreeNode, message::Add, service)
    me.size += 1
    if isnothing(me.splitvalue)
        push!(me.values, message.value)
        if length(me.values) > ITEMS_PER_LEAF
            split(me, service)
        end
    else
        if message.value > me.splitvalue
            send(service, me, me.right, message)
        else
            send(service, me, me.left, message)
        end
    end
end

function onmessage(me::TreeNode, message::RecipientMoved, service) # TODO a default implementation like this
    oldbox = box(message.oldaddress)
    if !isnothing(me.left) && box(me.left) === oldbox
        me.left = message.newaddress
    elseif !isnothing(me.right) && box(me.right) === oldbox
        me.right = message.newaddress
    elseif !isnothing(me.sibling) && box(me.sibling) == oldbox
        me.sibling = message.newaddress
    end
    send(service, me, message.newaddress, message.originalmessage)
end

function onmessage(me::TreeNode{T}, message::Search{T}, service) where T
    if isnothing(me.splitvalue)
        if message.value in me.values
            send(service, me, message.searcher, SearchResult(message.value, true))
        else
            send(service, me, message.searcher, SearchResult(message.value, false))
        end
    else
        child = message.value > me.splitvalue ? me.right : me.left
        send(service, me, child, message)
    end
    if SIBLINGINFO_FREQ > 0 && !isnothing(me.sibling) && rand(UInt8) < SIBLINGINFO_FREQ
        send(service, me, me.sibling, SiblingInfo(me.size), -1) # To push the sibling away
    end
end

function onmessage(me::TreeNode, message::SetSibling, service)
    me.sibling = message.value
end

# No need to handle the message for the infoton to work
#function onmessage(me::TreeNode, message::SiblingInfo, service) end

end

zygote() = SearchTreeTest.Coordinator()
