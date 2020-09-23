# SPDX-License-Identifier: LGPL-3.0-only
# This test builds a binary tree of TreeActors, growing a new level for every
# Start message received by the TreeCreator.
# The growth of every leaf is reported back by its parent to the
# TreeCreator, which counts the nodes in the tree.

using Test
using CircoCore
import CircoCore.onmessage

struct Start end

struct GrowRequest
    creator::Addr
end

struct GrowResponse
    leafsgrown::Int
end

mutable struct TreeActor{TCore} <: AbstractActor{TCore}
    left::Addr
    right::Addr
    core::TCore
end
TreeActor(core) = TreeActor(Addr(), Addr(), core)

function onmessage(me::TreeActor, message::GrowRequest, service)
    if CircoCore.isnulladdr(me.left)
        me.left = spawn(service, TreeActor(emptycore(service)))
        me.right = spawn(service, TreeActor(emptycore(service)))
        send(service, me, message.creator, GrowResponse(2))
    else
        send(service, me, me.left, message)
        send(service, me, me.right, message)
    end
end

mutable struct TreeCreator{TCore} <: AbstractActor{TCore}
    nodecount::Int64
    root::Addr
    core::TCore
end
TreeCreator(core) = TreeCreator(0, Addr(), core)

function onmessage(me::TreeCreator, ::Start, service)
    if CircoCore.isnulladdr(me.root)
        me.root = spawn(service, TreeActor(emptycore(service)))
        me.nodecount = 1
    end
    send(service, me, me.root, GrowRequest(addr(me)))
end

function onmessage(me::TreeCreator, message::GrowResponse, service)
    me.nodecount += message.leafsgrown
end

@testset "Actor" begin
    @testset "Actor-Tree" begin
        ctx = CircoContext()
        creator = TreeCreator(emptycore(ctx))
        scheduler = ActorScheduler(ctx, [creator])#; msgqueue_capacity=2_000_000
        for i in 1:17
            deliver!(scheduler, addr(creator), Start())
            @time scheduler(;process_external = false, exit_when_done = true)
            @test creator.nodecount == 2^(i+1)-1
        end
        shutdown!(scheduler)
    end
end
