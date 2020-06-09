using Documenter, CircoCore

makedocs(;
    modules=[CircoCore],
    format=Documenter.HTML(
        assets = ["assets/favicon.ico"]
    ),
    pages=[
        "index.md",
        "install.md",
        "sample.md",
        "reference.md",
        "troubleshooting.md",
    ],
    repo="https://github.com/Circo-dev/CircoCore/blob/{commit}{path}#L{line}",
    sitename="CircoCore",
    authors="Krisztián Schaffer",
)

deploydocs(;
    repo="github.com/Circo-dev/CircoCore",
)
