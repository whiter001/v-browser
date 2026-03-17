$env:V_BROWSER_EXTENSION_ID = "eefgklfpdnjodmmjefedjfnflacaimmj"
$env:V_BROWSER_BROWSER_APP = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', 47979)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($stream)

$writer.WriteLine('{"id":1,"method":"connect","params":{}}')
$response = $reader.ReadLine()
Write-Host "Response: $response"
$client.Close()
