# SPDX-License-Identifier: LGPL-3.0-only
using Base.Threads

const MSG_BUFFER_SIZE = 100_000

mutable struct HostActor <: AbstractActor
    core::CoreState
    HostActor() = new()
end
monitorprojection(::Type{HostActor}) = JS("projections.nonimportant")


mutable struct HostService <: Plugin
    in_msg::Deque
    in_lock::SpinLock
    iamzygote
    peers::Dict{PostCode, HostService}
    helper::Addr
    postcode::PostCode
    HostService(;options=NamedTuple()) = new(
        Deque{Any}(),#get(options, :buffer_size, MSG_BUFFER_SIZE)
        SpinLock(),
        get(options, :iamzygote, false),
        Dict()
    )
end

symbol(::HostService) = :host
postcode(hs::HostService) = hs.postcode

function Plugins.setup!(hs::HostService, scheduler)
    hs.postcode = postcode(scheduler)
    hs.helper = spawn(scheduler.service, HostActor())
end

function addpeers!(hs::HostService, peers::Array{HostService}, scheduler)
    for peer in peers
        if postcode(peer) != postcode(hs)
            hs.peers[postcode(peer)] = peer
        end
    end
    cluster = get(scheduler.plugins, :cluster, nothing)
    if !isnothing(cluster) && !hs.iamzygote && length(cluster.roots) == 0
        root = peers[1].postcode
        deliver!(scheduler, Msg(cluster.helper, ForceAddRoot(root))) # TODO avoid using the inner API
    end
end

@inline function remoteroutes(hostservice::HostService, scheduler::AbstractActorScheduler, msg::AbstractMsg)::Bool
    target_postcode =  postcode(target(msg))
    if network_host(target_postcode) !=  network_host(hostservice.postcode)
        return false
    end
    #@debug "remoteroutes in host.jl $msg"
    peer = get(hostservice.peers, target_postcode, nothing)
    if !isnothing(peer)
        #@debug "Inter-thread delivery of $(hostservice.postcode): $msg"
        lock(peer.in_lock)
        try
            push!(peer.in_msg, msg)
        finally
            unlock(peer.in_lock)
        end
        return true
    end
    return false
end

@inline function letin_remote(hs::HostService, scheduler::AbstractActorScheduler)::Bool
    isempty(hs.in_msg) && return false
    msgs = []
    lock(hs.in_lock)
    try
        for i = 1:min(length(hs.in_msg), 30)
            push!(msgs, pop!(hs.in_msg))
            #@debug "arrived at $(hs.postcode): $msg"
        end
    finally
        unlock(hs.in_lock)
    end
    for msg in msgs # The lock must be released before delivering (hostroutes now aquires the peer lock)
        deliver!(scheduler, msg) 
    end
    return false
end

struct Host
    schedulers::Array{ActorScheduler}
end

function Host(threadcount::Int, pluginsfun = core_plugins; options=NamedTuple())
    schedulers = create_schedulers(threadcount, pluginsfun, options)
    hostservices = [scheduler.plugins[:host] for scheduler in schedulers]
    addpeers(hostservices, schedulers)
    return Host(schedulers)
end

function create_schedulers(threadcount::Number, pluginsfun, options)
    zygote = get(options, :zygote, [])
    schedulers = []
    for i = 1:threadcount
        iamzygote = i == 1
        myzygote = iamzygote ? zygote : nothing
        scheduler = ActorScheduler(myzygote;plugins=[HostService(;options=(iamzygote = iamzygote, options...)), pluginsfun(;options=options)...])
        push!(schedulers, scheduler)
    end
    return schedulers
end

function addpeers(hostservices::Array{HostService}, schedulers)
    for i in 1:length(hostservices)
        addpeers!(hostservices[i], hostservices, schedulers[i])
    end
end

# From https://discourse.julialang.org/t/lightweight-tasks-julia-vs-elixir-otp/35082/22
function onthread(f::F, id::Int) where {F<:Function}
    t = Task(nothing)
    @assert id in 1:Threads.nthreads() "thread $id not available!"
    Threads.@threads for i in 1:Threads.nthreads()
        if i == id
            t = @async f()
        end
    end
    return t
end

function (ts::Host)(;process_external=true, exit_when_done=false)
    tasks = []
    current_threadid = 2
    for scheduler in ts.schedulers
        sleep(length(tasks) in (4:length(ts.schedulers) - 4)  ? 0.1 : 1.0) # TODO sleeping is a workaround for a bug in cluster.jl
        push!(tasks, onthread(current_threadid) do; scheduler(;process_external=process_external, exit_when_done=exit_when_done); end)
        current_threadid = current_threadid == Threads.nthreads() ? 1 : current_threadid + 1 
    end
    for task in tasks
        wait(task)
    end
    return nothing
end

function (host::Host)(message::AbstractMsg;process_external=true, exit_when_done=false)
    deliver!(host.schedulers[1], message)
    host(;process_external=process_external,exit_when_done=exit_when_done)
    return nothing
end

function shutdown!(host::Host)
    for scheduler in host.schedulers
        shutdown!(scheduler)
    end
end
