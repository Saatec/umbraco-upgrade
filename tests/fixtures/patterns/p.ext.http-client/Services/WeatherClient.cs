using System.Net.Http;
using Microsoft.Extensions.Configuration;

namespace SampleSite.Web.Services;

// Synthetic fixture: a static client shared by every request.
public class WeatherClient
{
    private static readonly HttpClient Client = new HttpClient();
    private readonly IConfiguration _configuration;

    public WeatherClient(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    public async Task<string> GetForecastAsync(string city)
    {
        var baseUrl = _configuration["WeatherApi:BaseUrl"];
        var key = _configuration["WeatherApi:ApiKey"];
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl}forecast?city={Uri.EscapeDataString(city)}");
        request.Headers.Add("X-Api-Key", key);
        var response = await Client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync();
    }
}
