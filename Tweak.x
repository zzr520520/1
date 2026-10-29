#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface AutoAddFriendViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *msgInputField;     // 验证附言输入框
@property (nonatomic, strong) UISlider *intervalSlider;       // 间隔时间滑块
@property (nonatomic, strong) UILabel *intervalLabel;
@property (nonatomic, strong) UILabel *statusLabel;           // 进度状态显示
@property (nonatomic, strong) UIButton *actionButton;         // 开始/停止按钮

@property (nonatomic, strong) NSMutableArray *groupList;      // 已加群列表
@property (nonatomic, strong) NSMutableSet *selectedGids;     // 选中的群Gid
@property (nonatomic, strong) NSMutableArray *pendingMembers; // 待添加的群成员队列
@property (nonatomic, strong) NSTimer *sendTimer;
@property (nonatomic, assign) BOOL isRunning;

@end

@implementation AutoAddFriendViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自动添加群好友";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.groupList = [NSMutableArray array];
    self.selectedGids = [NSMutableSet set];
    self.pendingMembers = [NSMutableArray array];
    
    [self setupControlPanel];
    [self setupTableView];
    [self loadJoinedGroups];
}

#pragma mark - UI 布局

- (void)setupControlPanel {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 180)];
    headerView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    
    // 1. 验证消息输入
    self.msgInputField = [[UITextField alloc] initWithFrame:CGRectMake(16, 15, self.view.bounds.size.width - 32, 38)];
    self.msgInputField.placeholder = @"请输入验证附言（如：你好，群里看到的）";
    self.msgInputField.borderStyle = UITextBorderStyleRoundedRect;
    self.msgInputField.text = @"你好，同一个群的，加个好友交流下~";
    [headerView addSubview:self.msgInputField];
    
    // 2. 发送间隔控制（防风控）
    self.intervalLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 65, 200, 20)];
    self.intervalLabel.font = [UIFont systemFontOfSize:14];
    self.intervalLabel.text = @"发送间隔: 5.0 秒 (建议 ≥3秒)";
    [headerView addSubview:self.intervalLabel];
    
    self.intervalSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, 90, self.view.bounds.size.width - 32, 30)];
    self.intervalSlider.minimumValue = 1.5;
    self.intervalSlider.maximumValue = 15.0;
    self.intervalSlider.value = 5.0;
    [self.intervalSlider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [headerView addSubview:self.intervalSlider];
    
    // 3. 状态与启动按钮
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 130, self.view.bounds.size.width - 130, 36)];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"状态：请勾选下方群聊";
    [headerView addSubview:self.statusLabel];
    
    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.frame = CGRectMake(self.view.bounds.size.width - 106, 130, 90, 36);
    self.actionButton.backgroundColor = [UIColor systemBlueColor];
    [self.actionButton setTitle:@"开始添加" forState:UIControlStateNormal];
    [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.actionButton.layer.cornerRadius = 8;
    [self.actionButton addTarget:self action:@selector(toggleAutoAdd) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:self.actionButton];
    
    [self.view addSubview:headerView];
}

- (void)setupTableView {
    CGFloat topY = 180;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];
}

- (void)sliderValueChanged:(UISlider *)sender {
    self.intervalLabel.text = [NSString stringWithFormat:@"发送间隔: %.1f 秒 (建议 ≥3秒)", sender.value];
}

#pragma mark - 核心逻辑 1：读取已加入的群聊

- (void)loadJoinedGroups {
    self.statusLabel.text = @"正在读取本地群列表...";
    
    // 方案 A：从本地 WCDB 数据库或缓存管理类中读取群列表
    // 根据逆向报告，可定位 FFSecretSignalAddFriendVC 或 Linkman 模块中的群组数据源
    // 这里演示数据结构封装，实际对接时将 Hook 到的 Pb_GroupInfo 数组传入即可
    
    /* 
     示例：动态获取宿主工程中的群列表缓存
     Class groupMgrCls = objc_getClass("_TtC6FFChat16FFGroupViewModel"); // 需根据实际符号名微调
     */
    
    // 模拟已获取到的群数据字典（对接时替换为真实的 Pb_GroupInfo 属性读取）
    // KVC 读取示例: [pbGroupInfo valueForKey:@"gid"], [pbGroupInfo valueForKey:@"name"]
    [self.tableView reloadData];
    self.statusLabel.text = [NSString stringWithFormat:@"已加载 %lu 个群聊", (unsigned long)self.groupList.count];
}

#pragma mark - 核心逻辑 2：获取群成员并加入发送队列

- (void)toggleAutoAdd {
    if (self.isRunning) {
        [self stopAutoAdd:@"已手动停止"];
        return;
    }
    
    if (self.selectedGids.count == 0) {
        self.statusLabel.text = @"⚠️ 请至少勾选一个群！";
        return;
    }
    
    self.isRunning = YES;
    [self.actionButton setTitle:@"停止" forState:UIControlStateNormal];
    self.actionButton.backgroundColor = [UIColor systemRedColor];
    self.statusLabel.text = @"正在拉取群成员列表...";
    
    [self.pendingMembers removeAllObjects];
    
    // 遍历选中的群，拉取所有群成员 (对接 /user/group/member/list)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSNumber *gid in self.selectedGids) {
            NSArray *members = [self fetchMembersForGroup:gid];
            for (id member in members) {
                // 过滤掉自己 (Uid: 1515017) 和群管理员 (admin > 0)
                NSNumber *uid = [member valueForKey:@"uid"];
                NSNumber *admin = [member valueForKey:@"admin"];
                if (uid.longLongValue != 1515017 && admin.intValue == 0) {
                    [self.pendingMembers addObject:member];
                }
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pendingMembers.count == 0) {
                [self stopAutoAdd:@"未找到可添加的群成员"];
                return;
            }
            [self startSendQueue];
        });
    });
}

- (void)startSendQueue {
    NSTimeInterval interval = self.intervalSlider.value;
    self.sendTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(processNextMember) userInfo:nil repeats:YES];
    [self processNextMember]; // 立即执行第一个
}

- (void)processNextMember {
    if (self.pendingMembers.count == 0) {
        [self stopAutoAdd:@"✅ 全部群成员添加完毕！"];
        return;
    }
    
    id memberInfo = [self.pendingMembers firstObject];
    [self.pendingMembers removeObjectAtIndex:0];
    
    NSNumber *targetUid = [memberInfo valueForKey:@"uid"];
    NSString *targetName = [memberInfo valueForKey:@"name"] ?: [targetUid stringValue];
    NSString *ticket = [memberInfo valueForKey:@"ticket"] ?: @"";
    NSNumber *gid = [memberInfo valueForKey:@"gid"];
    
    self.statusLabel.text = [NSString stringWithFormat:@"正在添加: %@ (剩余 %lu 人)", targetName, (unsigned long)self.pendingMembers.count];
    
    // 执行发送好友申请
    [self sendFriendApplyWithUid:targetUid groupId:gid ticket:ticket message:self.msgInputField.text];
}

- (void)stopAutoAdd:(NSString *)reason {
    self.isRunning = NO;
    if (self.sendTimer) {
        [self.sendTimer invalidate];
        self.sendTimer = nil;
    }
    [self.actionButton setTitle:@"开始添加" forState:UIControlStateNormal];
    self.actionButton.backgroundColor = [UIColor systemBlueColor];
    self.statusLabel.text = reason;
}

#pragma mark - 核心逻辑 3：对接蝙蝠底层发送接口

- (NSArray *)fetchMembersForGroup:(NSNumber *)gid {
    // 方式：触发 FFGroupMemberListVC 的 VM 请求，或直接读取本地数据库已缓存的群成员
    // 如果群已经被点开过，WCDB 本地库中通常已经有群成员缓存，直接查库或从 VM 读取最快
    return @[]; 
}

- (void)sendFriendApplyWithUid:(NSNumber *)fid groupId:(NSNumber *)gid ticket:(NSString *)ticket message:(NSString *)msg {
    /*
     对接说明：
     在蝙蝠 3.8.5 中，添加好友由 FFAddFriendInputMsgVC 或 FFUserInfoVC 触发。
     最稳妥的挂钩方式：
     */
    
    // 1. 获取 SwiftProtobuf 中的 Pb_FriendAddQuery 或 Pb_FriendApplyQuery 类
    // 注意：Swift struct 无法直接用 objc_getClass 实例化，因此我们直接调用 ViewModel 的 Objective-C 暴露方法，或者通过内存捕获网络发包函数。
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.groupList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"GroupCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    
    id group = self.groupList[indexPath.row];
    NSNumber *gid = [group valueForKey:@"gid"];
    NSString *name = [group valueForKey:@"name"];
    NSNumber *nums = [group valueForKey:@"nums"];
    
    cell.textLabel.text = name ?: [NSString stringWithFormat:@"群号: %@", gid];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"成员数: %@ 人 | GID: %@", nums, gid];
    cell.accessoryType = [self.selectedGids containsObject:gid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id group = self.groupList[indexPath.row];
    NSNumber *gid = [group valueForKey:@"gid"];
    
    if ([self.selectedGids containsObject:gid]) {
        [self.selectedGids removeObject:gid];
    } else {
        [self.selectedGids addObject:gid];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
