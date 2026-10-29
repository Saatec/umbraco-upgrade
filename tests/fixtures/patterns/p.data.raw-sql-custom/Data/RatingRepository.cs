using Umbraco.Cms.Infrastructure.Scoping;

namespace SampleSite.Web.Data;

// Synthetic fixture: raw SQL over a custom table.
public class RatingRepository
{
    private readonly IScopeProvider _scopeProvider;

    public RatingRepository(IScopeProvider scopeProvider)
    {
        _scopeProvider = scopeProvider;
    }

    public List<int> TopScores()
    {
        using var scope = _scopeProvider.CreateScope(autoComplete: true);
        return scope.Database.Fetch<int>("SELECT TOP 10 Score FROM sampleRating ORDER BY Score DESC");
    }
}
