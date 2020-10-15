# SPDX-License-Identifier: MPL-2.0

# julia -i -q --color=yes --project revise.jl example

using Revise, Jive
using CircoCore

trigger = function (path)
    printstyled("changed ", color=:cyan)
    println(path)
    revise()
    runtests(@__DIR__, skip=["revise.jl"])
end

watch(trigger, @__DIR__, sources=[pathof(CircoCore)])
trigger("")

Base.JLOptions().isinteractive==0 && wait()
