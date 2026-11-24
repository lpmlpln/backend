import Foundation
import MealPlannerCore
import Vapor

extension UserDTO: @retroactive Content {}
extension TokenPair: @retroactive Content {}
extension MagicLinkRequest: @retroactive Content {}
extension MagicLinkResponse: @retroactive Content {}
extension AppleSignInRequest: @retroactive Content {}
extension RefreshRequest: @retroactive Content {}
extension DeviceRegistration: @retroactive Content {}

extension RecipeDTO: @retroactive Content {}
extension IngredientDTO: @retroactive Content {}
extension RecipeImageDTO: @retroactive Content {}
extension PersonalizationDTO: @retroactive Content {}
extension RecipeCreateRequest: @retroactive Content {}
extension RecipeImportRequest: @retroactive Content {}
extension RecipeImportResponse: @retroactive Content {}
extension ImportJobDTO: @retroactive Content {}
extension PlanEntryUpdateRequest: @retroactive Content {}
extension FriendRequestLike: Content {}
extension LockRequest: Content {}
extension FriendRequest: @retroactive Content {}

struct RecipeListResponse: Content {
    var items: [RecipeDTO]
    var nextCursor: String?
}

extension PlanDTO: @retroactive Content {}
extension PlanEntryDTO: @retroactive Content {}
extension PlanMemberDTO: @retroactive Content {}
extension PlanCreateRequest: @retroactive Content {}
extension PlanUpdateRequest: @retroactive Content {}
extension RecalculateRequest: @retroactive Content {}
extension PlanMemberRequest: @retroactive Content {}
extension ShoppingListDTO: @retroactive Content {}
extension ShoppingItemDTO: @retroactive Content {}
extension ShoppingCheckRequest: @retroactive Content {}

extension FriendDTO: @retroactive Content {}

extension SyncPullResponse: @retroactive Content {}
extension SyncPushRequest: @retroactive Content {}
extension SyncPushResponse: @retroactive Content {}
extension APIErrorBody: @retroactive Content {}
