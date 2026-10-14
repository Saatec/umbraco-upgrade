var builder = WebApplication.CreateBuilder(args);
builder.Services.AddEndpointsApiExplorer();

var app = builder.Build();
app.MapGet("/hello", () => "Hello");
app.Run();
