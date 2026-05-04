Set-StrictMode -Version Latest

function Get-VirtuaCamSoftwareArtifacts {
    @(
        "VirtuaCam.exe",
        "VirtuaCamProcess.exe",
        "DirectPortBroker.dll",
        "DirectPortClient.dll",
        "DirectPortConsumer.dll"
    )
}

function Get-VirtuaCamRuntimeArtifacts {
    @(
        "msvcp140.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll"
    )
}

function Get-VirtuaCamDriverArtifacts {
    @(
        "avshws.sys",
        "avshws.inf",
        "avshws.cat",
        "VirtualCameraDriver-TestSign.cer"
    )
}

function Get-VirtuaCamInstallArtifacts {
    @(
        (Get-VirtuaCamSoftwareArtifacts) +
        (Get-VirtuaCamRuntimeArtifacts) +
        (Get-VirtuaCamDriverArtifacts)
    )
}
