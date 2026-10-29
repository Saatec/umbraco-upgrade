using Umbraco.Cms.Core.PropertyEditors;
using Umbraco.Cms.Core.Services;

namespace SampleSite.Web.Services;

// Synthetic fixture: builds dropdown options from a data type configuration.
public class RegionOptions
{
    private readonly IDataTypeService _dataTypeService;

    public RegionOptions(IDataTypeService dataTypeService)
    {
        _dataTypeService = dataTypeService;
    }

    public IEnumerable<string> Names()
    {
        var dataType = _dataTypeService.GetDataType("Regions");
        var config = dataType?.ConfigurationAs<ValueListConfiguration>();
        return config?.Items.Select(i => i.Value ?? string.Empty) ?? Enumerable.Empty<string>();
    }
}
