using System;
using Umbraco.Core.Models.PublishedContent;
using Umbraco.Core.PropertyEditors;

namespace SampleSite.Web
{
    // Synthetic fixture: converts the stored badge value.
    public class BadgeValueConverter : PropertyValueConverterBase
    {
        public override bool IsConverter(IPublishedPropertyType propertyType)
            => propertyType.EditorAlias.Equals("SampleSite.Badge");

        public override Type GetPropertyValueType(IPublishedPropertyType propertyType) => typeof(string);
    }
}
