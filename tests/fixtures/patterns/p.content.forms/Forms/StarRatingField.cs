using Umbraco.Forms.Core;

namespace SampleSite.Web.Forms;

// Synthetic fixture: a custom forms field type.
public class StarRatingField : FieldType
{
    public StarRatingField()
    {
        Id = new Guid("00000000-0000-0000-0000-000000000201");
        Name = "Star rating";
        Description = "A rating from one to five stars.";
    }
}
